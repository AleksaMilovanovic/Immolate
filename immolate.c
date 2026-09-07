#include "lib/immolate.h"
#include "lib/supplier.h"
#include <time.h>

// Launch a 1-D kernel over numGroups work-groups. If the driver rejects the
// work-group size for this kernel, halve it once and retry; the new geometry is
// written back so later launches use it too.
static cl_int enqueue_1d(cl_command_queue queue, cl_kernel kernel, size_t* globalSize, size_t* localSize, unsigned int numGroups) {
    cl_int err = clEnqueueNDRangeKernel(queue, kernel, 1, NULL, globalSize, localSize, 0, NULL, NULL);
    if (err == CL_INVALID_WORK_GROUP_SIZE && *localSize > 1) {
        printf_s("Work-group size %zu rejected by the driver, retrying with %zu.\n", *localSize, *localSize / 2);
        *localSize /= 2;
        *globalSize = (size_t)numGroups * *localSize;
        err = clEnqueueNDRangeKernel(queue, kernel, 1, NULL, globalSize, localSize, 0, NULL, NULL);
    }
    return err;
}

int main(int argc, char **argv) {
    
    // Print version
    printf_s("Immolate Beta v1.0.1f.1\n");

    // Handle CLI arguments
    unsigned int platformID = 0;
    unsigned int deviceID = 0;
    unsigned int numGroups = 0; // 0 = derive from the device's compute unit count
    int noCache = 0;
    int verboseBuild = 0;
    int singlePass = 0;
    cl_long prefilterBatch = 1 << 26; // 67M seeds per pass-1 batch: 512 MB survivor buffer worst case
    int progressEvery = 0;
    const char* toFile = NULL;   // --to: write passing seeds to a supplier file
    const char* fromFile = NULL; // --from: take seeds from a supplier file
    int toParts = 1;             // --to_parts: split --to output into this many numbered files
    const char* resumeFile = NULL; // --resume: continue an interrupted --to run from this part file
    cl_long forcedStartRank = -1;  // start rank restored from a resumed file's header
    char resumeBase[MAX_PATH + 64]; // --to path derived from the resumed file's name
    int resumePart = 1;            // part index parsed from the resumed file's name
    cl_char8 startingSeed;
    for (int i = 0; i < 8; i++) {
        startingSeed.s[i] = '\0';
    };
    cl_long numSeeds = 2318107019761;
    cl_long cutoff = 1;
    char* filter = "erratic_flush_five";
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-h")==0) {
            printf_s("Valid command line arguments:\n-h        Shows this help dialog.\n-f <F>    Sets the filter used by Immolate to F. Defaults to erratic_flush_five.\n-s <S>    Sets the starting seed to S. Defaults to empty seed. Use \"random\" for a random starting seed.\n-n <N>    Sets the number of seeds to search to N. Defaults to full seed pool.\n-c <C>    Prints every seed whose score is at least C. Defaults to 1.\n-p <P>    Sets the platform ID of the CL device being used to P. Defaults to 0.\n-d <D>    Sets the device ID of the CL device being used to D. Defaults to 0.\n-g <G>    Sets the number of work-groups to G. Defaults to 16 per compute unit on the selected device. Use -g 1 with -n 1 for single-seed analysis.\n\n--list_devices   Lists information about the detected CL devices.\n--no_cache       Do not load or save the compiled kernel binary (forces a full rebuild).\n--verbose_build  Print the kernel compiler's log (register usage and spills on NVIDIA). Implies --no_cache.\n--single_pass    Ignore a filter's prefilter and run everything in one pass.\n--batch <B>      Seeds per prefilter batch in a two-pass search. Defaults to 67108864.\n--progress <P>   In a batched search, print progress to stderr every P batches. Defaults to off.\n--to <FILE>      Write every seed whose score is at least the cutoff to seed-supplier file FILE instead of printing it.\n--from <FILE>    Search only the seeds listed in seed-supplier file FILE (made with --to) instead of a rank range. -n caps how many are read. Prefilters are skipped.\n--to_parts <K>   Split the --to output into K files, FILE.part1of<K> .. FILE.part<K>of<K>, each covering an equal share of the input seeds (-n, or the whole pool). Defaults to 1.\n--resume <PART>  Continue an interrupted --to run. PART is the part file that was being written (e.g. pool.seeds.part12of24); the filter, cutoff, output name, part count and range come from it, and the search restarts just after the last seed it holds. Pass the same --from if the original run used one.");
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
        if (strcmp(argv[i],  "--single_pass")==0) {
            // Ignore the filter's prefilter and run the plain single-pass kernel.
            singlePass = 1;
        }
        if (strcmp(argv[i],  "--batch")==0) {
            prefilterBatch = strtoll(argv[i+1], NULL, 10);
            if (prefilterBatch < 1) prefilterBatch = 1;
            i++;
        }
        if (strcmp(argv[i],  "--progress")==0) {
            progressEvery = atoi(argv[i+1]);
            i++;
        }
        if (strcmp(argv[i],  "--to")==0) {
            toFile = argv[i+1];
            i++;
        }
        if (strcmp(argv[i],  "--from")==0) {
            fromFile = argv[i+1];
            i++;
        }
        if (strcmp(argv[i],  "--resume")==0) {
            resumeFile = argv[i+1];
            i++;
        }
        if (strcmp(argv[i],  "--to_parts")==0) {
            toParts = atoi(argv[i+1]);
            if (toParts < 1) toParts = 1;
            i++;
        }
        if (strcmp(argv[i],  "--verbose_build")==0) {
            // Print the compiler's build log even on success. On NVIDIA this
            // includes ptxas register counts and spill stores. Forces a source build.
            verboseBuild = 1;
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
    // --resume: everything about the run is taken from the interrupted part
    // file, so it cannot be resumed under different settings by mistake. Any
    // conflicting flag on this command line is an error, not a silent override.
    int userFilter = 0, userCutoff = 0, userTo = 0, userParts = 0, userN = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-f") == 0) userFilter = 1;
        if (strcmp(argv[i], "-c") == 0) userCutoff = 1;
        if (strcmp(argv[i], "-n") == 0) userN = 1;
        if (strcmp(argv[i], "--to") == 0) userTo = 1;
        if (strcmp(argv[i], "--to_parts") == 0) userParts = 1;
    }
    static char resumeFilter[64];
    if (resumeFile) {
        // Name: <base>[.part<P>of<K>]
        strcpy_s(resumeBase, sizeof resumeBase, resumeFile);
        int rParts = 1;
        resumePart = 1;
        char* suffix = strrchr(resumeBase, '.');
        if (suffix && strncmp(suffix, ".part", 5) == 0) {
            int pp = 0, kk = 0, used = 0;
            if (sscanf(suffix + 5, "%dof%d%n", &pp, &kk, &used) == 2 && suffix[5 + used] == '\0' && pp >= 1 && kk >= pp) {
                resumePart = pp;
                rParts = kk;
                *suffix = '\0';
            }
        }
        FILE* rf = fopen(resumeFile, "rb");
        if (!rf) { fprintf_s(stderr, "Cannot open %s to resume.\n", resumeFile); exit(EXIT_FAILURE); }
        unsigned char hb[SUP_HEADER_SIZE];
        size_t got = fread(hb, 1, SUP_HEADER_SIZE, rf);
        fclose(rf);
        sup_header rh;
        const char* herr = got == SUP_HEADER_SIZE ? sup_decode_header(hb, &rh) : "file too short for a header";
        if (herr) { fprintf_s(stderr, "Cannot resume from %s: %s.\n", resumeFile, herr); exit(EXIT_FAILURE); }
        if ((rh.flags & SUP_FLAG_FROM_FILE) && !fromFile) { fprintf_s(stderr, "--resume: %s was made from a supplier file (--from); pass the same --from to resume it.\n", resumeFile); exit(EXIT_FAILURE); }
        if (!(rh.flags & SUP_FLAG_FROM_FILE) && fromFile) { fprintf_s(stderr, "--resume: %s was made from a seed range, not from a supplier file; drop --from to resume it.\n", resumeFile); exit(EXIT_FAILURE); }
        if (userFilter && strcmp(filter, rh.filter) != 0) { fprintf_s(stderr, "--resume: %s was made with filter %s, not %s.\n", resumeFile, rh.filter, filter); exit(EXIT_FAILURE); }
        if (userCutoff && cutoff != (cl_long)rh.cutoff) { fprintf_s(stderr, "--resume: %s was made with cutoff %lld, not %lld.\n", resumeFile, (long long)rh.cutoff, (long long)cutoff); exit(EXIT_FAILURE); }
        if (userTo && strcmp(toFile, resumeBase) != 0) { fprintf_s(stderr, "--resume: %s belongs to output %s, not %s.\n", resumeFile, resumeBase, toFile); exit(EXIT_FAILURE); }
        if (userParts && toParts != rParts) { fprintf_s(stderr, "--resume: %s is one of %d parts, not %d.\n", resumeFile, rParts, toParts); exit(EXIT_FAILURE); }
        strcpy_s(resumeFilter, sizeof resumeFilter, rh.filter);
        filter = resumeFilter;
        cutoff = (cl_long)rh.cutoff;
        toFile = resumeBase;
        toParts = rParts;
        if (!fromFile) {
            // Range run: the header holds the original -s rank and -n.
            if (userN && numSeeds != (cl_long)rh.num_seeds) { fprintf_s(stderr, "--resume: %s covers %lld seeds, not %lld.\n", resumeFile, (long long)rh.num_seeds, (long long)numSeeds); exit(EXIT_FAILURE); }
            forcedStartRank = (cl_long)rh.start_rank;
            numSeeds = (cl_long)rh.num_seeds;
        }
        printf_s("Resuming %s: filter %s, cutoff %lld, part %d of %d.\n", resumeFile, filter, (long long)cutoff, resumePart, toParts);
    }
    cl_int err;

    // Load the kernel source code into the array ssKernel
    FILE *fp;
    char *ssKernelCode;
    char *ssKernelBuf;
    size_t ssKernelSize;

    // Get CWD
    char executable_dir[MAX_PATH];
    char include_path[MAX_PATH+32];
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
    if (verboseBuild) {
        strcat_s(include_path, sizeof include_path, " -cl-nv-verbose");
    }
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
                printf_s("Loaded compiled kernel from cache (sources hashed under %s%slib and %s%sfilters).\n", executable_dir, PATH_SEPARATOR, executable_dir, PATH_SEPARATOR);
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
    if (verboseBuild && err == CL_INVALID_BUILD_OPTIONS) {
        printf_s("This driver rejected -cl-nv-verbose (it is NVIDIA-only); rebuilding without it.\n");
        char* opt = strstr(include_path, " -cl-nv-verbose");
        if (opt) *opt = '\0';
        err = clBuildProgram(ssKernelProgram, 1, &device, include_path, NULL, NULL);
    }
    if (err == CL_BUILD_PROGRAM_FAILURE || (verboseBuild && builtFromSource)) { //print build log on error, or always when asked
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

    // search, search_ranks and the two collecting kernels are always present.
    // search_prefilter exists only when the filter defines HAS_PREFILTER (see
    // search.cl); its absence is the normal single-pass case, not an error.
    cl_kernel ranksKernel = clCreateKernel(ssKernelProgram, "search_ranks", &err);
    clErrCheck(err, "clCreateKernel - Creating search_ranks kernel");
    cl_kernel collectKernel = clCreateKernel(ssKernelProgram, "search_collect", &err);
    clErrCheck(err, "clCreateKernel - Creating search_collect kernel");
    cl_kernel ranksCollectKernel = clCreateKernel(ssKernelProgram, "search_ranks_collect", &err);
    clErrCheck(err, "clCreateKernel - Creating search_ranks_collect kernel");
    cl_int errPre = CL_SUCCESS;
    cl_kernel preKernel = clCreateKernel(ssKernelProgram, "search_prefilter", &errPre);
    if (errPre != CL_SUCCESS) preKernel = NULL;
    // A supplier file is already a list of seeds, so --from runs the full filter
    // on it directly; the prefilter would only add a pass.
    int twoPass = (preKernel != NULL && !singlePass && fromFile == NULL);

    cl_long startRank = forcedStartRank >= 0 ? forcedStartRank : seed_rank(&startingSeed);
    err = clSetKernelArg(ssKernel, 0, sizeof(startRank), &startRank);
    clErrCheck(err, "clSetKernelArg - Adding starting rank argument");
    err = clSetKernelArg(ssKernel, 1, sizeof(numSeeds), &numSeeds);
    clErrCheck(err, "clSetKernelArg - Adding number of seeds argument");
    err = clSetKernelArg(ssKernel, 2, sizeof(cutoff), &cutoff);
    clErrCheck(err, "clSetKernelArg - Adding cutoff argument");
    err = clSetKernelArg(ranksKernel, 2, sizeof(cutoff), &cutoff);
    clErrCheck(err, "clSetKernelArg - Adding cutoff argument");
    err = clSetKernelArg(collectKernel, 2, sizeof(cutoff), &cutoff);
    clErrCheck(err, "clSetKernelArg - Adding cutoff argument");
    err = clSetKernelArg(ranksCollectKernel, 2, sizeof(cutoff), &cutoff);
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
        numGroups = computeUnits * 16;
    }
    size_t globalSize = (size_t)numGroups * localSize;
    printf_s("Launching %zu work-groups of %zu work-items (%zu total).\n", (size_t)numGroups, localSize, globalSize);

    // Seed-supplier input.
    sup_reader reader;
    if (fromFile) {
        const char* rerr = sup_reader_open(&reader, fromFile);
        if (rerr) {
            fprintf_s(stderr, "Cannot read seed-supplier file %s: %s.\n", fromFile, rerr);
            exit(EXIT_FAILURE);
        }
        printf_s("Reading %llu seeds from %s (filter %s, cutoff %lld).\n", (unsigned long long)reader.header.count, fromFile, reader.header.filter, (long long)reader.header.cutoff);
    }
    // Seed-supplier output. Opened before the search so a bad path fails fast.
    // The header's range is the rank range the pool descends from: under --from
    // that is the source file's range, not this run's -s/-n.
    //
    // With --to_parts K the input seeds (the -n range, or the file's count) are
    // cut into K equal slices and slice k's hits go to FILE.part<k>of<K>. Each
    // batch is clamped to end at a slice boundary, so a part switch only ever
    // happens between batches and every file stays sorted and self-contained.
    sup_writer writer;
    cl_long resumedFrom = 0;  // input index this run started at (--resume)
    cl_long hdrStart = 0, hdrNum = 0;
    uint32_t hdrFlags = 0;
    cl_long partInputs = 0;   // input seeds per part
    cl_long partEnd = 0;      // input count at which the current part ends
    int partIndex = 0;        // 1-based part currently open
    char partPath[MAX_PATH + 64];
    if (toFile) {
        hdrStart = fromFile ? (cl_long)reader.header.start_rank : startRank;
        hdrNum = fromFile ? (cl_long)reader.header.num_seeds : numSeeds;
        hdrFlags = fromFile ? SUP_FLAG_FROM_FILE : 0;
        cl_long inputs = numSeeds;
        if (fromFile && (cl_long)reader.header.count < inputs) inputs = (cl_long)reader.header.count;
        if ((cl_long)toParts > inputs) {
            printf_s("--to_parts %d exceeds the %lld input seeds; using %lld parts.\n", toParts, (long long)inputs, (long long)inputs);
            toParts = (int)inputs;
            if (toParts < 1) toParts = 1;
        }
        partInputs = (inputs + toParts - 1) / toParts; // ceil: the last part is the short one
        partIndex = 1;
        partEnd = toParts == 1 ? inputs : partInputs;
        if (toParts == 1) strcpy_s(partPath, sizeof partPath, toFile);
        else snprintf(partPath, sizeof partPath, "%s.part%dof%d", toFile, partIndex, toParts);
        if (resumeFile) {
            // Reopen the interrupted part and find where to pick up. The file
            // holds hits, not inputs, so the exact input the run died on is
            // unknown; restarting just after the last hit re-examines a few
            // seeds that did not pass, which write nothing, so no duplicates.
            partIndex = resumePart;
            partEnd = partIndex == toParts ? inputs : (cl_long)partIndex * partInputs;
            cl_long partStart = (cl_long)(partIndex - 1) * partInputs;
            sup_header rh;
            int64_t lastRank = -1;
            int complete = 0;
            const char* rerr = sup_writer_reopen(&writer, resumeFile, &rh, &lastRank, &complete);
            if (rerr) { fprintf_s(stderr, "Cannot resume from %s: %s.\n", resumeFile, rerr); exit(EXIT_FAILURE); }
            if (fromFile && ((cl_long)rh.start_rank != hdrStart || (cl_long)rh.num_seeds != hdrNum)) {
                fprintf_s(stderr, "--resume: %s descends from a different source than %s (range %lld+%lld vs %lld+%lld).\n",
                          resumeFile, fromFile, (long long)rh.start_rank, (long long)rh.num_seeds, (long long)hdrStart, (long long)hdrNum);
                exit(EXIT_FAILURE);
            }
            strcpy_s(partPath, sizeof partPath, resumeFile);
            cl_long resumeAt; // input index to continue from
            if (complete) {
                printf_s("%s is complete (%llu seeds).\n", resumeFile, (unsigned long long)writer.count);
                sup_writer_close(&writer);
                if (partIndex >= toParts) {
                    printf_s("That was the last part; nothing to resume.\n");
                    return EXIT_SUCCESS;
                }
                partIndex++;
                partEnd = partIndex == toParts ? inputs : (cl_long)partIndex * partInputs;
                partStart = (cl_long)(partIndex - 1) * partInputs;
                resumeAt = partStart;
                snprintf(partPath, sizeof partPath, "%s.part%dof%d", toFile, partIndex, toParts);
                if (!sup_writer_open(&writer, partPath, filter, cutoff, hdrStart, hdrNum, hdrFlags)) {
                    fprintf_s(stderr, "Cannot open %s for writing.\n", partPath);
                    exit(EXIT_FAILURE);
                }
                printf_s("Starting %s.\n", partPath);
            } else if (fromFile) {
                // Position the source after the last hit, but no earlier than the part's start.
                uint64_t skipped = lastRank >= 0 ? sup_reader_skip_through(&reader, lastRank) : 0;
                while ((cl_long)skipped < partStart) {
                    int64_t scratch[4096];
                    size_t want = (size_t)(partStart - (cl_long)skipped) < 4096 ? (size_t)(partStart - (cl_long)skipped) : 4096;
                    size_t g = sup_reader_next(&reader, scratch, want);
                    if (g == 0) break;
                    skipped += g;
                }
                resumeAt = (cl_long)skipped;
            } else {
                resumeAt = lastRank >= 0 ? lastRank + 1 - startRank : partStart;
                if (resumeAt < partStart) resumeAt = partStart;
            }
            if (resumeAt > partEnd) {
                fprintf_s(stderr, "--resume: %s holds seeds beyond its own part's range; wrong part number or -n?\n", resumeFile);
                exit(EXIT_FAILURE);
            }
            resumedFrom = resumeAt;
            printf_s("Continuing %s (%llu seeds so far) from input seed %lld of %lld; part ends at %lld.\n",
                     partPath, (unsigned long long)writer.count, (long long)resumeAt, (long long)inputs, (long long)partEnd);
        } else {
            if (!sup_writer_open(&writer, partPath, filter, cutoff, hdrStart, hdrNum, hdrFlags)) {
                fprintf_s(stderr, "Cannot open %s for writing.\n", partPath);
                exit(EXIT_FAILURE);
            }
            if (toParts == 1) printf_s("Writing seeds scoring at least %lld to %s.\n", (long long)cutoff, toFile);
            else printf_s("Writing seeds scoring at least %lld to %s.part1of%d .. part%dof%d, %lld input seeds each.\n",
                          (long long)cutoff, toFile, toParts, toParts, toParts, (long long)partInputs);
        }
    }

    // Execute OpenCL kernel
    printf_s("Starting searcher...\n");
    clock_t begin = clock();
    if (!twoPass && !toFile && !fromFile) {
        // Plain single pass: print straight from the kernel.
        err = enqueue_1d(queue, ssKernel, &globalSize, &localSize, numGroups);
        clErrCheck(err, "clEnqueueNDRangeKernel - Executing OpenCL kernel");
        err = clFlush(queue);
        err = clFinish(queue);
    } else {
        // Batched search. Seeds come from a rank range (walked in batches of
        // --batch) or from a supplier file (decoded in chunks); passing seeds go
        // to stdout or, with --to, are read back and appended to the file.
        // `listBuf` holds the packed rank list feeding a pass; `outBuf` and
        // `countBuf` receive a collecting kernel's hits. Both are sized to hold
        // every seed of a batch, so the kernels can never overflow them.
        const cl_long batchSeeds = prefilterBatch;
        cl_mem listBuf = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(cl_long) * (size_t)batchSeeds, NULL, &err);
        clErrCheck(err, "clCreateBuffer - Creating rank list buffer");
        cl_mem outBuf = NULL;
        if (toFile || twoPass) {
            // Two-pass writes pass-1 survivors to listBuf and pass-2 hits to outBuf;
            // --to needs outBuf for the hits.
            outBuf = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(cl_long) * (size_t)batchSeeds, NULL, &err);
            clErrCheck(err, "clCreateBuffer - Creating output buffer");
        }
        cl_mem countBuf = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(cl_uint), NULL, &err);
        clErrCheck(err, "clCreateBuffer - Creating count buffer");
        cl_long* hostRanks = NULL; // staging for file <-> device transfers
        if (toFile || fromFile) {
            hostRanks = (cl_long*)malloc(sizeof(cl_long) * (size_t)batchSeeds);
            if (!hostRanks) { fprintf_s(stderr, "Out of memory for a %lld-seed batch; lower --batch.\n", (long long)batchSeeds); exit(EXIT_FAILURE); }
        }
        // Pass 1 (prefilter) reads a range, writes survivors to listBuf.
        if (twoPass) {
            err = clSetKernelArg(preKernel, 2, sizeof(cl_mem), &listBuf);
            clErrCheck(err, "clSetKernelArg - Adding survivor buffer argument");
            err = clSetKernelArg(preKernel, 3, sizeof(cl_mem), &countBuf);
            clErrCheck(err, "clSetKernelArg - Adding survivor count argument");
        }
        // Range collect reads a range, writes hits to outBuf or listBuf.
        cl_mem collectOut = toFile ? outBuf : listBuf;
        err = clSetKernelArg(collectKernel, 3, sizeof(cl_mem), &collectOut);
        clErrCheck(err, "clSetKernelArg - Adding collect output argument");
        err = clSetKernelArg(collectKernel, 4, sizeof(cl_mem), &countBuf);
        clErrCheck(err, "clSetKernelArg - Adding collect count argument");
        // List kernels read listBuf; the collecting one writes hits to outBuf.
        err = clSetKernelArg(ranksKernel, 0, sizeof(cl_mem), &listBuf);
        clErrCheck(err, "clSetKernelArg - Adding ranks buffer argument");
        err = clSetKernelArg(ranksCollectKernel, 0, sizeof(cl_mem), &listBuf);
        clErrCheck(err, "clSetKernelArg - Adding ranks buffer argument");
        if (outBuf) {
            err = clSetKernelArg(ranksCollectKernel, 3, sizeof(cl_mem), &outBuf);
            clErrCheck(err, "clSetKernelArg - Adding ranks collect output argument");
        }
        err = clSetKernelArg(ranksCollectKernel, 4, sizeof(cl_mem), &countBuf);
        clErrCheck(err, "clSetKernelArg - Adding ranks collect count argument");

        if (fromFile) printf_s("Searching seeds from file in chunks of %lld.\n", (long long)batchSeeds);
        else if (twoPass) printf_s("Two-pass search: prefilter in batches of %lld seeds.\n", (long long)batchSeeds);
        else printf_s("Collecting search in batches of %lld seeds.\n", (long long)batchSeeds);

        cl_long totalIn = resumedFrom; // input index reached (seeds examined, plus any skipped by --resume)
        cl_long totalSurvivors = 0; // pass-1 survivors (two-pass only)
        cl_long totalOut = 0;       // seeds written to --to
        int batches = 0;
        const cl_uint zero = 0;
        for (;;) {
            // ---- Source: fill either a range or listBuf for this batch ----
            cl_long thisBatch = 0;   // range size, or list length
            cl_long batchStart = 0;
            int haveList = 0;        // seeds for this batch are in listBuf
            // Never read past the end of the current output part.
            cl_long batchCap = batchSeeds;
            if (toFile && partEnd - totalIn < batchCap) batchCap = partEnd - totalIn;
            if (fromFile) {
                if (totalIn >= numSeeds) break;
                size_t want = (size_t)(numSeeds - totalIn < batchCap ? numSeeds - totalIn : batchCap);
                size_t got = sup_reader_next(&reader, (int64_t*)hostRanks, want);
                if (got == 0) break;
                thisBatch = (cl_long)got;
                err = clEnqueueWriteBuffer(queue, listBuf, CL_TRUE, 0, sizeof(cl_long) * got, hostRanks, 0, NULL, NULL);
                clErrCheck(err, "clEnqueueWriteBuffer - Uploading seed list chunk");
                haveList = 1;
            } else {
                if (totalIn >= numSeeds) break;
                thisBatch = numSeeds - totalIn < batchCap ? numSeeds - totalIn : batchCap;
                batchStart = startRank + totalIn;
                if (twoPass) {
                    err = clEnqueueWriteBuffer(queue, countBuf, CL_TRUE, 0, sizeof(zero), &zero, 0, NULL, NULL);
                    clErrCheck(err, "clEnqueueWriteBuffer - Resetting survivor count");
                    err = clSetKernelArg(preKernel, 0, sizeof(batchStart), &batchStart);
                    clErrCheck(err, "clSetKernelArg - Adding batch start rank");
                    err = clSetKernelArg(preKernel, 1, sizeof(thisBatch), &thisBatch);
                    clErrCheck(err, "clSetKernelArg - Adding batch size");
                    err = enqueue_1d(queue, preKernel, &globalSize, &localSize, numGroups);
                    clErrCheck(err, "clEnqueueNDRangeKernel - Executing prefilter kernel");
                    cl_uint survivors = 0;
                    err = clEnqueueReadBuffer(queue, countBuf, CL_TRUE, 0, sizeof(survivors), &survivors, 0, NULL, NULL);
                    clErrCheck(err, "clEnqueueReadBuffer - Reading survivor count");
                    totalSurvivors += survivors;
                    totalIn += thisBatch;
                    thisBatch = survivors;
                    haveList = 1;
                }
            }

            // ---- Filter: run over the range or the list, print or collect ----
            cl_uint hits = 0;
            if (haveList) {
                if (thisBatch > 0) {
                    cl_kernel k = toFile ? ranksCollectKernel : ranksKernel;
                    err = clSetKernelArg(k, 1, sizeof(thisBatch), &thisBatch);
                    clErrCheck(err, "clSetKernelArg - Adding number of ranks");
                    if (toFile) {
                        err = clEnqueueWriteBuffer(queue, countBuf, CL_TRUE, 0, sizeof(zero), &zero, 0, NULL, NULL);
                        clErrCheck(err, "clEnqueueWriteBuffer - Resetting hit count");
                    }
                    // The list is short compared with a batch; do not launch more lanes than there is work.
                    size_t listGroups = ((size_t)thisBatch + localSize - 1) / localSize;
                    if (listGroups > (size_t)numGroups) listGroups = numGroups;
                    size_t listGlobal = listGroups * localSize;
                    err = clEnqueueNDRangeKernel(queue, k, 1, NULL, &listGlobal, &localSize, 0, NULL, NULL);
                    clErrCheck(err, "clEnqueueNDRangeKernel - Executing ranks kernel");
                    if (toFile) {
                        err = clEnqueueReadBuffer(queue, countBuf, CL_TRUE, 0, sizeof(hits), &hits, 0, NULL, NULL);
                        clErrCheck(err, "clEnqueueReadBuffer - Reading hit count");
                    } else {
                        err = clFinish(queue);
                        clErrCheck(err, "clFinish - Waiting for ranks kernel");
                    }
                }
                if (fromFile) totalIn += thisBatch;
            } else {
                // Range, collecting (single pass with --to).
                err = clEnqueueWriteBuffer(queue, countBuf, CL_TRUE, 0, sizeof(zero), &zero, 0, NULL, NULL);
                clErrCheck(err, "clEnqueueWriteBuffer - Resetting hit count");
                err = clSetKernelArg(collectKernel, 0, sizeof(batchStart), &batchStart);
                clErrCheck(err, "clSetKernelArg - Adding batch start rank");
                err = clSetKernelArg(collectKernel, 1, sizeof(thisBatch), &thisBatch);
                clErrCheck(err, "clSetKernelArg - Adding batch size");
                err = enqueue_1d(queue, collectKernel, &globalSize, &localSize, numGroups);
                clErrCheck(err, "clEnqueueNDRangeKernel - Executing collect kernel");
                err = clEnqueueReadBuffer(queue, countBuf, CL_TRUE, 0, sizeof(hits), &hits, 0, NULL, NULL);
                clErrCheck(err, "clEnqueueReadBuffer - Reading hit count");
                totalIn += thisBatch;
            }

            // ---- Sink: append this batch's hits to the supplier file ----
            if (toFile && hits > 0) {
                err = clEnqueueReadBuffer(queue, outBuf, CL_TRUE, 0, sizeof(cl_long) * hits, hostRanks, 0, NULL, NULL);
                clErrCheck(err, "clEnqueueReadBuffer - Reading collected ranks");
                if (!sup_writer_append(&writer, (int64_t*)hostRanks, hits)) {
                    fprintf_s(stderr, "Failed writing to %s.\n", toFile);
                    exit(EXIT_FAILURE);
                }
                totalOut += hits;
            }
            // Part boundary reached: close this part and open the next.
            if (toFile && toParts > 1 && totalIn >= partEnd && totalIn < numSeeds && partIndex < toParts) {
                if (!sup_writer_close(&writer)) {
                    fprintf_s(stderr, "Failed closing %s.\n", partPath);
                    exit(EXIT_FAILURE);
                }
                printf_s("Finished %s: %llu seeds.\n", partPath, (unsigned long long)writer.count);
                partIndex++;
                partEnd += partInputs;
                snprintf(partPath, sizeof partPath, "%s.part%dof%d", toFile, partIndex, toParts);
                if (!sup_writer_open(&writer, partPath, filter, cutoff, hdrStart, hdrNum, hdrFlags)) {
                    fprintf_s(stderr, "Cannot open %s for writing.\n", partPath);
                    exit(EXIT_FAILURE);
                }
            }
            batches++;
            if (progressEvery > 0 && batches % progressEvery == 0) {
                double elapsed = (double)(clock() - begin) / CLOCKS_PER_SEC;
                if (twoPass) fprintf(stderr, "[%lld / %lld seeds, %lld survivors, %lld written, %.1fs]\n",
                        (long long)totalIn, (long long)numSeeds, (long long)totalSurvivors, (long long)totalOut, elapsed);
                else fprintf(stderr, "[%lld seeds, %lld written, %.1fs]\n", (long long)totalIn, (long long)totalOut, elapsed);
            }
        }
        err = clFinish(queue);
        if (twoPass) printf_s("Prefilter passed %lld of %lld seeds.\n", (long long)totalSurvivors, (long long)totalIn);
        if (fromFile) printf_s("Searched %lld seeds from %s.\n", (long long)totalIn, fromFile);
        if (toFile) {
            if (!sup_writer_close(&writer)) {
                fprintf_s(stderr, "Failed closing %s.\n", partPath);
                exit(EXIT_FAILURE);
            }
            if (toParts > 1) printf_s("Finished %s: %llu seeds.\n", partPath, (unsigned long long)writer.count);
            if (resumedFrom > 0) printf_s("This run examined %lld seeds and wrote %lld.\n", (long long)(totalIn - resumedFrom), (long long)totalOut);
            else if (toParts > 1) printf_s("Wrote %lld of %lld seeds to %d files %s.part1of%d .. part%dof%d.\n", (long long)totalOut, (long long)totalIn, partIndex, toFile, toParts, partIndex, toParts);
            else printf_s("Wrote %lld of %lld seeds to %s.\n", (long long)totalOut, (long long)totalIn, toFile);
        }
        if (fromFile) sup_reader_close(&reader);
        free(hostRanks);
        clReleaseMemObject(listBuf);
        if (outBuf) clReleaseMemObject(outBuf);
        clReleaseMemObject(countBuf);
    }

    // Clean up
    if (preKernel) clReleaseKernel(preKernel);
    clReleaseKernel(ranksKernel);
    clReleaseKernel(collectKernel);
    clReleaseKernel(ranksCollectKernel);
    err = clReleaseKernel(ssKernel);
    err = clReleaseProgram(ssKernelProgram);
    err = clReleaseCommandQueue(queue);
    err = clReleaseContext(ctx);
    clock_t end = clock();
    double time_spent = (double)(end-begin) / CLOCKS_PER_SEC;
    printf("Done in %fs",time_spent);

    return EXIT_SUCCESS;
}