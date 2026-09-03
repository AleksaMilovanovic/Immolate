# Getting Started
## Setting up Immolate
Download the required files from the [Releases](https://github.com/MathIsFun0/Immolate/releases) page and unzip them into a directory of your choice.

Open the Immolate CLI in the directory you extracted Immolate to.

To check that Immolate works, run the command `immolate -h`. You should see a help dialog that lists all of the command-line arguments to pass into the searcher.

## Running an existing filter
To run an existing filter, type the name of the filter after the `-f` option, e.g. `immolate -f double_legendary`.

To run the executable, there are a few command line arguments that may be important.
- `-f`: Sets the filter used by the search.
- `-s`: Sets the starting seed of the search.
- `-n`: Sets the number of seeds of the search.
- `-c`: Sets the score the filter needs to return for a seed to be printed. Useful when searching for streaks or seeds that must meet a variety of conditions.
- `-p` and `-d`: Sets the platform and device IDs of the device Immolate uses to search. Running Immolate with `--list_devices` will give you the platform ID and device ID of every detected OpenCL device, which is needed for these commands. If you are having issues running Immolate, please check the [Troubleshooting](troubleshooting.md) section of the documentation.
- `-g`: Sets the number of work-groups launched by the searcher. The work-group size is chosen from the device automatically (32 or 64 work-items). If omitted, Immolate launches 32 work-groups per compute unit, which is usually enough to fill a GPU; try larger values if you want to experiment. Use `-g 1` together with `-n 1` for single-seed analysis.
- `--no_cache`: Skip the compiled-kernel cache. Immolate normally saves the compiled kernel under `.kernel_cache/` next to the executable and reuses it on later runs with the same filter, source files, device and driver, which avoids a multi-minute rebuild every run.

All of the [Existing Filters](existingfilters.md) are housed in the /filters folder. Explanations and usage guides are in the comments of each filter file.

## Seed Analysis
It's recommend to use [The Soul](https://mathisfun0.github.io/The-Soul/) to analyze a seed.

To print out all of the features in a seed using Immolate, you can use the analyzer filter. Edit analyzer.cl to set the deck and stake you want to use, and then run the following command: `immolate -f analyzer -s SEED -n 1 -g 1`

## Creating your own filter
As of now the only way to create your own filter is to program it yourself.
Take a look at the [Immolate Documentation](DOCUMENTATION.md) for more information.
