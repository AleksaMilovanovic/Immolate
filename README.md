# Immolate
An OpenCL seed searcher for Balatro.

## Getting Started
Please visit the [Getting Started](docs/getting_started.md) page in the documentation for tips on how to get started. If you are running into issues, please check the [Troubleshooting](docs/troubleshooting.md) page.

## Building and running from scratch (not recommended)

### Windows
Install cmake:
`winget install --id Kitware.CMake`

Install Visual Studio 2022 Build Tools:
`winget install Microsoft.VisualStudio.2022.BuildTools --force --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22000"`

Open the _x64 Native Tools Command Prompt for VS 2022_

Generate required files for building:
`cmake -G "Visual Studio 17 2022" -A x64 -B .\build`

Build:
`cmake --build .\build --config Release`

Run:
`.\build\Release\Immolate.exe`

### macOS

Apple GPUs cannot run the fp64 OpenCL kernels required by Immolate. Build with PoCL instead.

From the repository root:

```bash
xcode-select --install
brew install cmake pocl

OPENCL_LOADER="$(brew --prefix opencl-icd-loader)/lib/libOpenCL.dylib"
cmake -S . -B build-pocl \
  -DCMAKE_BUILD_TYPE=Release \
  -DOpenCL_LIBRARY="$OPENCL_LOADER"
cmake --build build-pocl --config Release

./build-pocl/Immolate -h
```

#### Troubleshooting

Confirm that the executable uses Homebrew's OpenCL loader:

```bash
otool -L build-pocl/Immolate | grep -E 'libOpenCL|OpenCL.framework'
```

The output should contain `libOpenCL.dylib`, not `OpenCL.framework`. If it does not, configure again with a new build-directory name.

If PoCL is not detected, check its ICD file and set the vendor directory:

```bash
ls -l "$(brew --prefix)/etc/OpenCL/vendors/pocl.icd"
export OCL_ICD_VENDORS="$(brew --prefix)/etc/OpenCL/vendors"
```

If CMake cannot locate the loader, build directly:

```bash
mkdir -p build-pocl
OPENCL_PREFIX="$(brew --prefix opencl-icd-loader)"
clang -O3 -std=gnu11 -DCL_TARGET_OPENCL_VERSION=120 \
  immolate.c \
  -L"$OPENCL_PREFIX/lib" \
  -Wl,-rpath,"$OPENCL_PREFIX/lib" \
  -lOpenCL \
  -o build-pocl/Immolate
```

### Linux (Debian)
Install dependencies:

```
sudo apt-get install cmake ocl-icd-opencl-dev build-essential
```

_NOTE: Remember to install the OpenCL driver depending on your hardware._

Build:
```
cmake -B build
cmake --build build --config Release
```

Run:
```
./build/Immolate
```

## Repository layout

- `filters/` — search filters: seeds in, a smaller set of seeds out.
- `diagnostics/` — timing and cost-attribution fixtures. Most deliberately return meaningless
  scores; they exist to be measured, not to search.
- `lib/` — the shared kernel: RNG, hashing, item tables, instance state.

`-f <name>` resolves a bare name in either `filters/` or `diagnostics/`.

## Correctness and performance tests

Run the complete regression and benchmark gate from the repository root:

```bash
python3 tests/run.py
```

The command saves its output under `test-results/`. See [tests/README.md](tests/README.md) for shorter profiles, device selection, golden updates, and exact checkout-to-checkout comparisons.

## Future Plans
- Full support with all features in Balatro 1.0.
- Support for AMD GPUs.
- Support for challenges.
- Saving output to a file.
- A GUI to interact with the searcher without having as much technical knowledge.
