# -*- coding: utf-8 -*-
cimport cython
from libc.stdint cimport uint32_t
import os

API_VERSION = 2


cdef extern from "_hashindex.c":
    ctypedef struct HashIndex:
        pass

    HashIndex *hashindex_read(char *path)
    HashIndex *hashindex_init(int capacity, int key_size, int value_size)
    void hashindex_free(HashIndex *index)
    void hashindex_summarize(HashIndex *index, long long *total_size, long long *total_csize,
                             long long *unique_size, long long *unique_csize,
                             long long *total_unique_chunks, long long *total_chunks)
    void hashindex_merge(HashIndex *index, HashIndex *other)
    int hashindex_get_size(HashIndex *index)
    int hashindex_write(HashIndex *index, char *path)
    void *hashindex_get(HashIndex *index, void *key)
    void *hashindex_next_key(HashIndex *index, void *key)
    int hashindex_delete(HashIndex *index, void *key)
    int hashindex_set(HashIndex *index, void *key, void *value)
    uint32_t htole32_(uint32_t v)
    uint32_t le32toh_(uint32_t v)


cdef _NoDefault = object()

@cython.internal
cdef class IndexBase:
    cdef HashIndex *index
    cdef int key_size

    def __cinit__(self, capacity=0, path=None, key_size=32):
        self.key_size = key_size
        if path:
            self.index = hashindex_read(os.fsencode(path))
            if not self.index:
                raise Exception('hashindex_read failed')
        else:
            self.index = hashindex_init(capacity, self.key_size, self.value_size)
            if not self.index:
                raise Exception('hashindex_init failed')

    def __dealloc__(self):
        if self.index:
            hashindex_free(self.index)

    @classmethod
    def read(cls, path):
        return cls(path=path)

    def write(self, path):
        if not hashindex_write(self.index, os.fsencode(path)):
            raise Exception('hashindex_write failed')

    def clear(self):
        hashindex_free(self.index)
        self.index = hashindex_init(0, self.key_size, self.value_size)
        if not self.index:
            raise Exception('hashindex_init failed')

    def setdefault(self, key, value):
        if not key in self:
            self[key] = value

    def __delitem__(self, key):
        assert len(key) == self.key_size
        if not hashindex_delete(self.index, <char *>key):
            raise Exception('hashindex_delete failed')

    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default

    def pop(self, key, default=_NoDefault):
        try:
            value = self[key]
            del self[key]
            return value
        except KeyError:
            if default != _NoDefault:
                return default
            raise

    def __len__(self):
        return hashindex_get_size(self.index)


cdef class NSIndex(IndexBase):

    value_size = 8

    def __getitem__(self, key):
        assert len(key) == self.key_size
        data = <int *>hashindex_get(self.index, <char *>key)
        if not data:
            raise KeyError
        return le32toh_(data[0]), le32toh_(data[1])

    def __setitem__(self, key, value):
        assert len(key) == self.key_size
        cdef uint32_t[2] data
        data[0] = htole32_(value[0])
        data[1] = htole32_(value[1])
        if not hashindex_set(self.index, <char *>key, data):
            raise Exception('hashindex_set failed')

    def __contains__(self, key):
        assert len(key) == self.key_size
        data = <int *>hashindex_get(self.index, <char *>key)
        return data != NULL

    def iteritems(self, marker=None):
        cdef const void *key
        iter = NSKeyIterator(self.key_size)
        iter.idx = self
        iter.index = self.index
        if marker:
            key = hashindex_get(self.index, <char *>marker)
            if marker is None:
                raise IndexError
            iter.key = key - self.key_size
        return iter


cdef class NSKeyIterator:
    cdef NSIndex idx
    cdef HashIndex *index
    cdef const void *key
    cdef int key_size

    def __cinit__(self, key_size):
        self.key = NULL
        self.key_size = key_size

    def __iter__(self):
        return self

    def __next__(self):
        self.key = hashindex_next_key(self.index, <char *>self.key)
        if not self.key:
            raise StopIteration
        cdef int *value = <int *>(self.key + self.key_size)
        return (<char *>self.key)[:self.key_size], (le32toh_(value[0]), le32toh_(value[1]))


cdef class ChunkIndex(IndexBase):

    value_size = 12

    def __getitem__(self, key):
        assert len(key) == self.key_size
        data = <int *>hashindex_get(self.index, <char *>key)
        if not data:
            raise KeyError
        return le32toh_(data[0]), le32toh_(data[1]), le32toh_(data[2])

    def __setitem__(self, key, value):
        assert len(key) == self.key_size
        cdef uint32_t[3] data
        data[0] = htole32_(value[0]) # overflow here (see EMPTY)
        data[1] = htole32_(value[1])
        data[2] = htole32_(value[2])
        if not hashindex_set(self.index, <char *>key, data):
            raise Exception('hashindex_set failed')

    def __contains__(self, key):
        assert len(key) == self.key_size
        data = <int *>hashindex_get(self.index, <char *>key)
        return data != NULL

    def iteritems(self, marker=None):
        cdef const void *key
        iter = ChunkKeyIterator(self.key_size)
        iter.idx = self
        iter.index = self.index
        if marker:
            key = hashindex_get(self.index, <char *>marker)
            if marker is None:
                raise IndexError
            iter.key = key - self.key_size
        return iter

    def summarize(self):
        cdef long long total_size, total_csize, unique_size, unique_csize, total_unique_chunks, total_chunks
        hashindex_summarize(self.index, &total_size, &total_csize,
                            &unique_size, &unique_csize,
                            &total_unique_chunks, &total_chunks)
        return total_size, total_csize, unique_size, unique_csize, total_unique_chunks, total_chunks

    def merge(self, ChunkIndex other):
        hashindex_merge(self.index, other.index)


cdef class ChunkKeyIterator:
    cdef ChunkIndex idx
    cdef HashIndex *index
    cdef const void *key
    cdef int key_size

    def __cinit__(self, key_size):
        self.key = NULL
        self.key_size = key_size

    def __iter__(self):
        return self

    def __next__(self):
        self.key = hashindex_next_key(self.index, <char *>self.key)
        if not self.key:
            raise StopIteration
        cdef int *value = <int *>(self.key + self.key_size)
        return (<char *>self.key)[:self.key_size], (le32toh_(value[0]), le32toh_(value[1]), le32toh_(value[2]))
