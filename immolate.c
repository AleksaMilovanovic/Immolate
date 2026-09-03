#include "lib/immolate.h"
#include <time.h>
int main(int argc, char **argv) {
    
    // Print version
    printf_s("Immolate Beta v1.0.1f.1\n");

    // Handle CLI arguments
    unsigned int platformID = 0;
    unsigned int deviceID = 0;
    unsigned int numGroups = 0; // 0 = derive from the device's compute unit count
    int noCache = 0;
    cl_char8 startingSeed;
    for (int i = 0; i < 8; i++) {
        startingSeed.s[i] = '\0';
    };
    cl_long numSeeds = 2318107019761;
    cl_long cutoff = 1;
    char* filter = "erratic_flush_five";
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-h")==0) {
            printf_s("Valid command line arguments:\n-h        Shows this help dialog.\n-f <F>    Sets the filter used by Immolate to F. Defaults to erratic_flush_five.\n-s <S>    Sets the starting seed to S. Defaults to empty seed. Use \"random\" for a random starting seed.\n-n <N>    Sets the number of seeds to search to N. Defaults to full seed pool.\n-c <C>    Prints every seed whose score is at least C. Defaults to 1.\n-p <P>    Sets the platform ID of the CL device being used to P. Defaults to 0.\n-d <D>    Sets the device ID of the CL device being used to D. Defaults to 0.\n-g <G>    Sets the number of work-groups to G. Defaults to 8 per compute unit on the selected device. Use -g 1 with -n 1 for single-seed analysis.\n\n--list_devices   Lists information about the detected CL devices.\n--no_cache       Do not load or save the compiled kernel binary (forces a full rebuild).");
            return 0;
        }
        if (strcmp(argv[i],  "-p")==0) {
            platformID = atoi(argv[i+1]);
            i++;
        }
        if (strcmp(argv[i],  "-f")==0) {
            filter = argv[i+1];
            i++;
        }
        if (strcmp(argv[i],  "-d")==0) {
            deviceID = atoi(argv[i+1]);
            i++;
        }
        if (strcmp(argv[i],  "-g")==0) {
            numGroups = atoi(argv[i+1]);
            i++;
        }
        if (strcmp(argv[i],  "-n")==0) {
            numSeeds = strtoll(argv[i+1], NULL, 10);
            i++;
        }
        if (strcmp(argv[i],  "-c")==0) {
            cutoff = strtoll(argv[i+1], NULL, 10);
            i++;
        }
        if (strcmp(argv[i],  "-s")==0) {
            if (strcmp(argv[i+1],"random")==0) {
                srand(time(NULL));
                char seedCharacters[] = {'1','2','3','4','5','6','7','8','9','A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z'};
                for (int j = 0; j < 8; j++) {
                    startingSeed.s[j] = seedCharacters[rand() % 35];
                }
            } else if (strlen(argv[i+1]) <= 8) {
                for (int j = 0; j < strlen(argv[i+1]); j++) {
                    startingSeed.s[j] = argv[i+1][j];
                }
                for (int j = strlen(argv[i+1]); j < 8; j++) {
                    startingSeed.s[j] = '\0';
                }
            } else {
                printf_s("Warning: Inputted seed is not valid, ignoring...\n");
            }
            i++;
        }
        if (strcmp(argv[i],  "--no_cache")==0) {
            noCache = 1;
        }
        if (strcmp(argv[i],  "--list_devices")==0) {
            cl_int err;
            char buf[1024];
            cl_uint temp_int;
            
            // Get # of OpenCL Platforms
            cl_uint numPlatforms;
            err = clGetPlatformIDs(0, NULL, &numPlatforms);
            clErrCheck(err, "clGetPlatformIDs - Getting number of available OpenCL platforms");

            // Nothing available? Then leave!
            if (numPlatforms == 0) {
                printf_s("No OpenCL devices found.\n");
                return 0;
            }

            // Now get OpenCL Platforms
            cl_platform_id* platforms = malloc(sizeof(cl_platform_id) * numPlatforms);

            err = clGetPlatformIDs(numPlatforms, platforms, NULL);
            clErrCheck(err, "clGetPlatformIDs - Getting list of availble OpenCL platforms");

            int foundDevice = 0;
            for (unsigned int p = 0; p < numPlatforms; p++) {
                //Now we do the same thing for devices...
                cl_uint numDevices;
                err = clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, 0, NULL, &numDevices);
                clErrCheck(err, "clGetDeviceIDs - Getting number of available OpenCL devices");

                if (numDevices > 0) foundDevice = 1;

                cl_device_id* devices = malloc(sizeof(cl_device_id) * numDevices);
                err = clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, numDevices, devices, NULL);
                clErrCheck(err, "clGetDeviceIDs - Getting list of available OpenCL devices");

                for (unsigned int d = 0; d < numDevices; d++) {
                    printf_s("Platform ID %i, Device ID %i\n", p, d);

                    // Get Device Info
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_NAME, sizeof(buf), &buf, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device name");
                    printf_s("Name: %s\n", buf);
                    
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_VENDOR, sizeof(buf), &buf, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device vendor");
                    printf_s("Vendor: %s\n", buf);
                    
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(temp_int), &temp_int, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device compute units");
                    printf_s("Compute Units: %i\n", temp_int);
                    
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_MAX_CLOCK_FREQUENCY, sizeof(temp_int), &temp_int, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device clock frequency");
                    printf_s("Clock Frequency: %iMHz\n", temp_int);
                }
            }
            if (foundDevice == 0) {
                printf_s("No OpenCL devices found.\n");
            }
            return 0;
        }
    }
    cl_int err;

    // Load the kernel source code into the array ssKernel
    FILE *fp;
    char *ssKernelCode;
    char *ssKernelBuf;
    size_t ssKernelSize;

    // Get CWD
    char executable_dir[MAX_PATH];
    char include_path[MAX_PATH+6];
    char kernel_path[MAX_PATH+12];
    getExecutableDir(executable_dir);
    strcpy_s(kernel_path, sizeof kernel_path, executable_dir);
    strcat_s(kernel_path, sizeof kernel_path, PATH_SEPARATOR);
    strcat_s(kernel_path, sizeof kernel_path, "search.cl");
    fp = fopen(kernel_path, "r");
    if (!fp) {
        printf_s("Warning: Kernel not found at ");
        printf_s("%s", kernel_path);
        printf_s(", attempting working directory...\n");
        fp = fopen("search.cl","r");
        if (!fp) {
            fprintf_s(stderr, "Failed to load kernel.\n");
            exit(1);
        }
        // The kernel sources live in the working directory, so the include
        // path, cache-key file hashing and cache directory must use it too.
        strcpy_s(executable_dir, sizeof executable_dir, ".");
    }
    strcpy_s(include_path, sizeof include_path, "-I \"");
    strcat_s(include_path, sizeof include_path, executable_dir);
    strcat_s(include_path, sizeof include_path, "\"");
    ssKernelCode = (char*)malloc(MAX_CODE_SIZE);
    ssKernelBuf = (char*)malloc(MAX_CODE_SIZE);
    // Set include information
    strcpy_s(ssKernelCode, MAX_CODE_SIZE, "#include \"filters/");
    strcat_s(ssKernelCode, MAX_CODE_SIZE, filter);
    strcat_s(ssKernelCode, MAX_CODE_SIZE, ".cl\"\n\n");
    size_t bytes_read = fread( ssKernelBuf, 1, MAX_CODE_SIZE - 1, fp);
    ssKernelBuf[bytes_read] = '\0';
    strcat_s(ssKernelCode, MAX_CODE_SIZE, ssKernelBuf);
    ssKernelSize = strlen(ssKernelCode);
    fclose( fp );
    free(ssKernelBuf);

    // Set up platform and device based on CLI args

    
    // Get # of OpenCL Platforms
    cl_uint numPlatforms;
    err = clGetPlatformIDs(0, NULL, &numPlatforms);
    clErrCheck(err, "clGetPlatformIDs - Getting number of available OpenCL platforms");

    // Nothing available? Then leave!
    if (numPlatforms == 0) {
        printf_s("No OpenCL platforms found.\n");
        return 0;
    }
    if (platformID > numPlatforms-1) {
        printf_s("Platform ID %i not found.\n", platformID);
        return 0;
    }

    // Now get OpenCL Platforms
    cl_platform_id* platforms = malloc(sizeof(cl_platform_id) * numPlatforms);

    err = clGetPlatformIDs(numPlatforms, platforms, NULL);
    clErrCheck(err, "clGetPlatformIDs - Getting list of availble OpenCL platforms");
    cl_platform_id platform = platforms[platformID];
    
    //Now we do the same thing for devices...
    cl_uint numDevices;
    err = clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 0, NULL, &numDevices);
    clErrCheck(err, "clGetDeviceIDs - Getting number of available OpenCL devices");

    if (numDevices == 0) {
        printf_s("No OpenCL devices found for platform %i.\n", platformID);
        return 0;
    }
    if (deviceID > numDevices-1) {
        printf_s("Device ID %i not found.\n", deviceID);
        return 0;
    }

    cl_device_id* devices = malloc(sizeof(cl_device_id) * numDevices);
    err = clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, numDevices, devices, NULL);
    clErrCheck(err, "clGetDeviceIDs - Getting list of available OpenCL devices");
    cl_device_id device = devices[deviceID];

    // Create an OpenCL context
    cl_context ctx = clCreateContext(NULL, 1, &device, NULL, NULL, &err);
    clErrCheck(err, "clCreateContext - Creating OpenCL context");
 
    // Create a command queue
    cl_command_queue queue = clCreateCommandQueue(ctx, device, 0, &err);
    clErrCheck(err, "clCreateCommandQueue - Creating OpenCL command queue");

    // Compiled-binary cache. The OpenCL front end takes minutes to compile this
    // kernel on some drivers, so keep the device binary on disk keyed on the
    // device, driver, build options, and the contents of every kernel source
    // file. Any failure falls back to a normal source build.
    char cache_path[MAX_PATH + 64];
    cache_path[0] = '\0';
    if (!noCache) {
        cl_ulong h = FNV_OFFSET;
        h = fnv1a_str(h, "immolate-kernel-cache-v1");
        h = fnv1a_str(h, include_path);
        h = fnv1a_device_info(h, device, CL_DEVICE_NAME);
        h = fnv1a_device_info(h, device, CL_DEVICE_VENDOR);
        h = fnv1a_device_info(h, device, CL_DEVICE_VERSION);
        h = fnv1a_device_info(h, device, CL_DRIVER_VERSION);
        h = fnv1a_buf(h, ssKernelCode, ssKernelSize); // includes the filter #include line
        int ok = 1;
        char src_path[MAX_PATH + 64];
        snprintf(src_path, sizeof src_path, "%s%sfilters%s%s.cl", executable_dir, PATH_SEPARATOR, PATH_SEPARATOR, filter);
        h = fnv1a_file(h, src_path, &ok);
        static const char* libFiles[] = {"immolate.cl", "util.cl", "seed.cl", "items.cl", "debug.cl", "cache.cl", "instance.cl", "functions.cl"};
        for (size_t i = 0; i < sizeof(libFiles) / sizeof(libFiles[0]); i++) {
            snprintf(src_path, sizeof src_path, "%s%slib%s%s", executable_dir, PATH_SEPARATOR, PATH_SEPARATOR, libFiles[i]);
            h = fnv1a_file(h, src_path, &ok);
        }
        if (ok) {
            char cache_dir[MAX_PATH + 32];
            snprintf(cache_dir, sizeof cache_dir, "%s%s.kernel_cache", executable_dir, PATH_SEPARATOR);
            make_dir(cache_dir);
            snprintf(cache_path, sizeof cache_path, "%s%s%016llx.bin", cache_dir, PATH_SEPARATOR, (unsigned long long)h);
        }
    }

    cl_program ssKernelProgram = NULL;
    int loadedFromCache = 0;
    if (cache_path[0] != '\0') {
        size_t binSize = 0;
        unsigned char* bin = read_whole_file(cache_path, &binSize);
        if (bin != NULL) {
            cl_int binStatus = CL_SUCCESS;
            ssKernelProgram = clCreateProgramWithBinary(ctx, 1, &device, &binSize, (const unsigned char**)&bin, &binStatus, &err);
            if (err == CL_SUCCESS && binStatus == CL_SUCCESS) {
                err = clBuildProgram(ssKernelProgram, 1, &device, include_path, NULL, NULL);
            }
            if (err != CL_SUCCESS || binStatus != CL_SUCCESS) {
                printf_s("Cached kernel binary could not be loaded, rebuilding from source...\n");
                if (ssKernelProgram != NULL) clReleaseProgram(ssKernelProgram);
                ssKernelProgram = NULL;
            } else {
                printf_s("Loaded compiled kernel from cache.\n");
                loadedFromCache = 1;
            }
            free(bin);
        }
    }

    int builtFromSource = 0;
    cl_kernel ssKernel = NULL;
build_program:
    if (ssKernelProgram == NULL) {
        // Create a program from kernel source
        ssKernelProgram = clCreateProgramWithSource(ctx, 1, (const char**)&ssKernelCode, (const size_t*)&ssKernelSize, &err);
        clErrCheck(err, "clCreateProgramWithSource - Creating OpenCL program");

        // Build the program
        printf_s("Building program...\n");
        err = clBuildProgram(ssKernelProgram, 1, &device, include_path, NULL, NULL);
        builtFromSource = 1;
    }
    if (err == CL_BUILD_PROGRAM_FAILURE) { //print build log on error
        size_t logLength = 0;
        err = clGetProgramBuildInfo(ssKernelProgram, device, CL_PROGRAM_BUILD_LOG, 0, NULL, &logLength);
        if (err != CL_SUCCESS) {
            printf_s("Error getting build log length: %d\n", err);
            return EXIT_FAILURE;
        }
        char *buf = calloc(logLength, sizeof(char));
        err = clGetProgramBuildInfo(ssKernelProgram, device, CL_PROGRAM_BUILD_LOG, logLength, buf, NULL);
        if (err != CL_SUCCESS) {
            printf_s("Error getting build log: %d\n", err);
            return EXIT_FAILURE;
        }
        printf_s("%s", buf);
        printf_s("\n");
    }
    clErrCheck(err, "clBuildProgram - Building OpenCL program");

    if (builtFromSource && cache_path[0] != '\0') {
        size_t binSize = 0;
        if (clGetProgramInfo(ssKernelProgram, CL_PROGRAM_BINARY_SIZES, sizeof(binSize), &binSize, NULL) == CL_SUCCESS && binSize > 0) {
            unsigned char* bin = malloc(binSize);
            unsigned char* bins[1] = {bin};
            if (clGetProgramInfo(ssKernelProgram, CL_PROGRAM_BINARIES, sizeof(bins), bins, NULL) == CL_SUCCESS) {
                FILE* cf = fopen(cache_path, "wb");
                if (cf) {
                    fwrite(bin, 1, binSize, cf);
                    fclose(cf);
                    printf_s("Saved compiled kernel to cache.\n");
                }
            }
            free(bin);
        }
    }

    // Create OpenCL kernel
    ssKernel = clCreateKernel(ssKernelProgram, "search", &err);
    if (err != CL_SUCCESS && loadedFromCache) {
        // A stale or corrupt cached binary can survive clBuildProgram on some
        // drivers and only fail here. Drop it and build from source once.
        printf_s("Cached kernel binary is unusable (error %d), rebuilding from source...\n", err);
        clReleaseProgram(ssKernelProgram);
        ssKernelProgram = NULL;
        remove(cache_path);
        loadedFromCache = 0;
        goto build_program;
    }
    clErrCheck(err, "clCreateKernel - Creating OpenCL kernel");

    // Set arguments
    err = clSetKernelArg(ssKernel, 0, sizeof(startingSeed), &startingSeed);
    clErrCheck(err, "clSetKernelArg - Adding starting seed argument");
    err = clSetKernelArg(ssKernel, 1, sizeof(numSeeds), &numSeeds);
    clErrCheck(err, "clSetKernelArg - Adding number of seeds argument");
    err = clSetKernelArg(ssKernel, 2, sizeof(cutoff), &cutoff);
    clErrCheck(err, "clSetKernelArg - Adding cutoff argument");

    // Launch geometry. Previously globalSize = G*G and localSize = G, so the
    // default -g 16 launched 256 work-items in half-warp groups and left almost
    // the entire GPU idle. Now the work-group size comes from the device and -g
    // is the number of work-groups, defaulting to 32 per compute unit.
    size_t preferredMultiple = 0;
    size_t maxWorkGroup = 0;
    err = clGetKernelWorkGroupInfo(ssKernel, device, CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE, sizeof(preferredMultiple), &preferredMultiple, NULL);
    if (err != CL_SUCCESS || preferredMultiple == 0) preferredMultiple = 32;
    err = clGetKernelWorkGroupInfo(ssKernel, device, CL_KERNEL_WORK_GROUP_SIZE, sizeof(maxWorkGroup), &maxWorkGroup, NULL);
    if (err != CL_SUCCESS || maxWorkGroup == 0) maxWorkGroup = preferredMultiple;
    // Use the preferred multiple as-is (32 on NVIDIA, 64 on AMD). Rounding it
    // up to 64 failed on an RTX 5080 with CL_INVALID_WORK_GROUP_SIZE: this
    // kernel's register footprint is large enough that 64 lanes do not fit in
    // one group, and the driver reports the device maximum rather than the
    // kernel's real limit for CL_KERNEL_WORK_GROUP_SIZE.
    size_t localSize = preferredMultiple;
    if (localSize > maxWorkGroup) localSize = maxWorkGroup;
    if (numGroups == 0) {
        cl_uint computeUnits = 1;
        err = clGetDeviceInfo(device, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(computeUnits), &computeUnits, NULL);
        if (err != CL_SUCCESS || computeUnits == 0) computeUnits = 1;
        numGroups = computeUnits * 8;
    }
    size_t globalSize = (size_t)numGroups * localSize;
    printf_s("Launching %zu work-groups of %zu work-items (%zu total).\n", (size_t)numGroups, localSize, globalSize);

    // Execute OpenCL kernel
    printf_s("Starting searcher...\n");
    clock_t begin = clock();
    err = clEnqueueNDRangeKernel(queue, ssKernel, 1, NULL, &globalSize, &localSize, 0, NULL, NULL);
    if (err == CL_INVALID_WORK_GROUP_SIZE && localSize > 1) {
        // The driver rejected the group size for this kernel. Halve it and retry.
        printf_s("Work-group size %zu rejected by the driver, retrying with %zu.\n", localSize, localSize / 2);
        localSize /= 2;
        globalSize = (size_t)numGroups * localSize;
        err = clEnqueueNDRangeKernel(queue, ssKernel, 1, NULL, &globalSize, &localSize, 0, NULL, NULL);
    }
    clErrCheck(err, "clEnqueueNDRangeKernel - Executing OpenCL kernel");

    // Clean up
    err = clFlush(queue);
    err = clFinish(queue);
    err = clReleaseKernel(ssKernel);
    err = clReleaseProgram(ssKernelProgram);
    err = clReleaseCommandQueue(queue);
    err = clReleaseContext(ctx);
    clock_t end = clock();
    double time_spent = (double)(end-begin) / CLOCKS_PER_SEC;
    printf("Done in %fs",time_spent);

    return EXIT_SUCCESS;
}