#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#ifdef _WIN32
    #include <windows.h>
    #define PATH_SEPARATOR "\\"
#else
    // Define undefined MAX_PATH in Linux
    #define MAX_PATH (1024)
    #define PATH_SEPARATOR "/"

    #include <unistd.h>
    #include <libgen.h>
    #ifdef __APPLE__
        #include <mach-o/dyld.h>
    #endif

    /* Use unsafe not _s functions
     * An alternative is using safeclib implementation with the following:
     *
     * #define __STDC_WANT_LIB_EXT1__ 1
     * #include <safeclib/safe_str_lib.h>
     * 
     * Unfortunately, the strcat_s and strcpy_s do not work for malloced strings
     */
    #define strcat_s(a,b,c) strcat(a,c)
    #define strcpy_s(a,b,c) strcpy(a,c)
    #define printf_s(...) printf(__VA_ARGS__)
    #define fprintf_s(...) fprintf(__VA_ARGS__)
#endif
#include <limits.h>
#include <string.h>
#ifdef _WIN32
    #include <direct.h>
#else
    #include <sys/stat.h>
#endif
#ifdef __APPLE__
    #include <OpenCL/cl.h>
#else
    #include <CL/cl.h>
#endif
#define MAX_CODE_SIZE (1000000)

// FNV-1a hashing for the compiled-kernel cache key
#define FNV_OFFSET ((cl_ulong)14695981039346656037ULL)
#define FNV_PRIME ((cl_ulong)1099511628211ULL)
cl_ulong fnv1a_buf(cl_ulong h, const void* data, size_t len) {
    const unsigned char* p = (const unsigned char*)data;
    for (size_t i = 0; i < len; i++) {
        h ^= p[i];
        h *= FNV_PRIME;
    }
    return h;
}
cl_ulong fnv1a_str(cl_ulong h, const char* s) {
    return fnv1a_buf(h, s, strlen(s) + 1);
}
unsigned char* read_whole_file(const char* path, size_t* outLen) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    unsigned char* buf = malloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { free(buf); return NULL; }
    buf[n] = '\0';
    *outLen = (size_t)n;
    return buf;
}
// Hashes a source file's contents into h; clears *ok if the file cannot be read.
cl_ulong fnv1a_file(cl_ulong h, const char* path, int* ok) {
    size_t n = 0;
    unsigned char* buf = read_whole_file(path, &n);
    if (!buf) { *ok = 0; return h; }
    h = fnv1a_str(h, path);
    h = fnv1a_buf(h, buf, n);
    free(buf);
    return h;
}
cl_ulong fnv1a_device_info(cl_ulong h, cl_device_id device, cl_device_info param) {
    char buf[1024];
    buf[0] = '\0';
    clGetDeviceInfo(device, param, sizeof(buf), buf, NULL);
    return fnv1a_str(h, buf);
}
// Rank of a seed string in the bijective base-35 order the kernel walks:
// "" = 0, "1".."Z" = 1..35, "11" = 36, ... "ZZZZZZZZ" = 2318107019760.
cl_long seed_rank(const cl_char8* s) {
    static const char chars[] = "123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    cl_long rank = 0;
    for (int i = 0; i < 8 && s->s[i] != '\0'; i++) {
        const char* p = strchr(chars, s->s[i]);
        int digit = p ? (int)(p - chars) : 0;
        rank = rank * 35 + digit + 1;
    }
    return rank;
}
void make_dir(const char* path) {
    #ifdef _WIN32
        _mkdir(path);
    #else
        mkdir(path, 0755);
    #endif
}

void clErrCheck(cl_int err, char* msg) {
    if (err != CL_SUCCESS) {
        printf_s("Fatal CL Error %d when trying to execute %s\n", err, msg);
        exit(EXIT_FAILURE);
    }
}

void getExecutableDir(char *dir) {
    #ifdef _WIN32
        // Windows specific code
         if (GetModuleFileName(NULL, dir, MAX_PATH) != 0) {
            char* last_slash = strrchr(dir, '\\');
            if (last_slash != NULL) {
                *last_slash = '\0';
            }
        } else {
            fprintf(stderr, "Error: Unable to get the current working directory\n");
        }
    #elif __linux__
        // Linux specific code
        ssize_t len = readlink("/proc/self/exe", dir, (size_t)(MAX_PATH - 1));
        if (len != -1) {
            dir[len] = '\0';
            char* last_slash = strrchr(dir, '/');
            if (last_slash != NULL) {
                *last_slash = '\0';
            }
        } else {
            fprintf(stderr, "Error: Unable to get the current working directory\n");
            // exit(EXIT_FAILURE);
        }
    #elif __APPLE__
        uint32_t size = MAX_PATH;
        if (_NSGetExecutablePath(dir, &size) == 0) {
            char* last_slash = strrchr(dir, '/');
            if (last_slash != NULL) {
                *last_slash = '\0';
            }
        } else {
            fprintf(stderr, "Error: Unable to get the current working directory\n");
        }
    #else
        #error Platform not supported
    #endif
}