#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE

#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sendfile.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <unistd.h>

FILE *shim_fopen64(const char *path, const char *mode) __asm__("fopen64");
FILE *shim_fopen64(const char *path, const char *mode)
{
    return fopen(path, mode);
}

int shim_fstatfs64(int fd, void *buf) __asm__("fstatfs64");
int shim_fstatfs64(int fd, void *buf)
{
    return fstatfs(fd, (struct statfs *)buf);
}

int shim_fstatvfs64(int fd, void *buf) __asm__("fstatvfs64");
int shim_fstatvfs64(int fd, void *buf)
{
    return fstatvfs(fd, (struct statvfs *)buf);
}

int shim_ftruncate64(int fd, off64_t length) __asm__("ftruncate64");
int shim_ftruncate64(int fd, off64_t length)
{
    return ftruncate(fd, (off_t)length);
}

int shim_getrlimit64(int resource, void *limit) __asm__("getrlimit64");
int shim_getrlimit64(int resource, void *limit)
{
    return getrlimit(resource, (struct rlimit *)limit);
}

off64_t shim_lseek64(int fd, off64_t offset, int whence) __asm__("lseek64");
off64_t shim_lseek64(int fd, off64_t offset, int whence)
{
    return (off64_t)lseek(fd, (off_t)offset, whence);
}

int shim_mkstemp64(char *template) __asm__("mkstemp64");
int shim_mkstemp64(char *template)
{
    return mkstemp(template);
}

void *shim_mmap64(void *address, size_t length, int protection, int flags,
                  int fd, off64_t offset) __asm__("mmap64");
void *shim_mmap64(void *address, size_t length, int protection, int flags,
                  int fd, off64_t offset)
{
    return mmap(address, length, protection, flags, fd, (off_t)offset);
}

int shim_open64(const char *path, int flags, ...) __asm__("open64");
int shim_open64(const char *path, int flags, ...)
{
    mode_t mode = 0;

    if ((flags & O_CREAT) != 0) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
#ifdef O_TMPFILE
    else if ((flags & O_TMPFILE) == O_TMPFILE) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
#endif

    return open(path, flags, mode);
}

int shim_posix_fadvise64(int fd, off64_t offset, off64_t length, int advice)
    __asm__("posix_fadvise64");
int shim_posix_fadvise64(int fd, off64_t offset, off64_t length, int advice)
{
    return posix_fadvise(fd, (off_t)offset, (off_t)length, advice);
}

int shim_posix_fallocate64(int fd, off64_t offset, off64_t length)
    __asm__("posix_fallocate64");
int shim_posix_fallocate64(int fd, off64_t offset, off64_t length)
{
    return posix_fallocate(fd, (off_t)offset, (off_t)length);
}

ssize_t shim_pread64(int fd, void *buffer, size_t count, off64_t offset)
    __asm__("pread64");
ssize_t shim_pread64(int fd, void *buffer, size_t count, off64_t offset)
{
    return pread(fd, buffer, count, (off_t)offset);
}

ssize_t shim_pwrite64(int fd, const void *buffer, size_t count, off64_t offset)
    __asm__("pwrite64");
ssize_t shim_pwrite64(int fd, const void *buffer, size_t count, off64_t offset)
{
    return pwrite(fd, buffer, count, (off_t)offset);
}

void *shim_readdir64(DIR *directory) __asm__("readdir64");
void *shim_readdir64(DIR *directory)
{
    return (struct dirent64 *)readdir(directory);
}

ssize_t shim_sendfile64(int output_fd, int input_fd, off64_t *offset,
                        size_t count) __asm__("sendfile64");
ssize_t shim_sendfile64(int output_fd, int input_fd, off64_t *offset,
                        size_t count)
{
    return sendfile(output_fd, input_fd, (off_t *)offset, count);
}

int shim_setrlimit64(int resource, const void *limit) __asm__("setrlimit64");
int shim_setrlimit64(int resource, const void *limit)
{
    return setrlimit(resource, (const struct rlimit *)limit);
}

int shim_statfs64(const char *path, void *buf) __asm__("statfs64");
int shim_statfs64(const char *path, void *buf)
{
    return statfs(path, (struct statfs *)buf);
}

int shim_statvfs64(const char *path, void *buf) __asm__("statvfs64");
int shim_statvfs64(const char *path, void *buf)
{
    return statvfs(path, (struct statvfs *)buf);
}

int shim_fcntl64(int fd, int command, ...) __asm__("fcntl64");
int shim_fcntl64(int fd, int command, ...)
{
    if (command == F_GETFD || command == F_GETFL
#ifdef F_GETOWN
        || command == F_GETOWN
#endif
#ifdef F_GETSIG
        || command == F_GETSIG
#endif
#ifdef F_GETLEASE
        || command == F_GETLEASE
#endif
#ifdef F_GETPIPE_SZ
        || command == F_GETPIPE_SZ
#endif
#ifdef F_GET_SEALS
        || command == F_GET_SEALS
#endif
    ) {
        return fcntl(fd, command);
    }

    va_list args;
    va_start(args, command);
    long argument = va_arg(args, long);
    va_end(args);
    return fcntl(fd, command, argument);
}
