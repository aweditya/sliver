#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <string>
#include <vector>
#include "KernelWrapper.h"
#include "ClockBlockKernel.h"
#include "RoundRobinScheduler.h"
#include "FCFSScheduler.h"

#define NUM_KERNELS 10

CUdevice device;
int clockRate;
CUcontext context;
size_t totalGlobalMem;

void initCuda()
{
    int deviceCount = 0;
    checkCudaErrors(cuInit(0));
    int major = 0, minor = 0;

    checkCudaErrors(cuDeviceGetCount(&deviceCount));

    if (deviceCount == 0)
    {
        fprintf(stderr, "Error: no devices supporting CUDA\n");
        exit(-1);
    }

    // get first CUDA device
    checkCudaErrors(cuDeviceGet(&device, 0));
    char name[100];
    cuDeviceGetName(name, 100, device);
    printf("> Using device 0: %s\n", name);

    // get device properties
    checkCudaErrors(cuDeviceGetAttribute(&clockRate, CU_DEVICE_ATTRIBUTE_CLOCK_RATE, device));

    // get compute capabilities and the devicename
    checkCudaErrors(cuDeviceComputeCapability(&major, &minor, device));
    printf("> GPU Device has SM %d.%d compute capability\n", major, minor);

    checkCudaErrors(cuDeviceTotalMem(&totalGlobalMem, device));
    printf("  Total amount of global memory:   %llu bytes\n",
           (unsigned long long)totalGlobalMem);
    printf("  64-bit Memory Address:           %s\n",
           (totalGlobalMem > (unsigned long long)4 * 1024 * 1024 * 1024L) ? "YES" : "NO");

    checkCudaErrors(cuCtxCreate(&context, 0, device));
}

void finishCuda()
{
    cuCtxDetach(context);
}

int main(int argc, char **argv)
{
    initCuda();
    srand(0);

    RoundRobinScheduler scheduler;
    // FCFSScheduler scheduler;

    const std::string moduleFile = "./ptx/clockBlock.ptx";
    const std::string kernelName = "clockBlock";

    CUstream streams[NUM_KERNELS];
    std::vector<ClockBlockKernel> clockBlockKernels;
    clockBlockKernels.reserve(NUM_KERNELS);

    kernel_attr_t attrs[NUM_KERNELS];
    std::vector<KernelWrapper> wrappers;
    for (int i = 0; i < NUM_KERNELS; ++i)
    {
        checkCudaErrors(cuStreamCreate(&streams[i], CU_STREAM_DEFAULT));
        attrs[i] = {
            .gridDimX = 8,
            .gridDimY = 1,
            .gridDimZ = 1,
            .blockDimX = 128,
            .blockDimY = 1,
            .blockDimZ = 1,
            .sGridDimX = 8 / 4,
            .sGridDimY = 1,
            .sGridDimZ = 1,
            .sharedMemBytes = 0,
            .stream = streams[i]};

        clockBlockKernels.emplace_back(clockRate);
        KernelWrapper wrapper(&scheduler, context, moduleFile, kernelName, &attrs[i], &clockBlockKernels[i]);
        wrappers.emplace_back(wrapper);
    }

    struct timeval t0, t1, dt;
    gettimeofday(&t0, NULL);

    scheduler.run();

    for (int i = 0; i < NUM_KERNELS; ++i)
    {
        wrappers[i].launch();
    }

    for (int i = 0; i < NUM_KERNELS; ++i)
    {
        wrappers[i].finish();
    }

    scheduler.stop();
    scheduler.finish();

    gettimeofday(&t1, NULL);
    timersub(&t1, &t0, &dt);
    printf("[main thread] done in %ld.%06ld\n", dt.tv_sec, dt.tv_usec);

    for (int i = 0; i < NUM_KERNELS; ++i)
    {
        checkCudaErrors(cuStreamDestroy(streams[i]));
    }

    finishCuda();

    return 0;
}
