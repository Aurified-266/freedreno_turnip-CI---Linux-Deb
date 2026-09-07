# 🛠️ Mesa-Turnip Continued Integration / Continued Development
>## *Turnip Graphics Driver Build Script / Build Repo for - `Linux-Debian and Android`*

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
![Platform](https://img.shields.io/badge/Platform-Android%2013%2B-green.svg)
![Device](https://img.shields.io/badge/Device-Retroid%20Pocket%205-orange.svg)
![Status](https://img.shields.io/badge/Status-Stable-success.svg)
![Status](https://img.shields.io/badge/Status-Developer-success.svg)

### *TLDR*;

This is a bash script to build *Vulkan Only* Turnip Drivers for android as a magisk module and adpkg. Made specifically for compatibilty with Linux-Debian architecture. Linux-Deb users may have encountered a host of problems when attempting to cross-compile the bash script originally given by ilhan-athn7 and later forked by k11mch1; this new bash script fixes issues caused by lack of *implicit* and *explicit* dependencies, lack of explicit work environment definition, and amends missing non-linux "*native*" host-lib-functions. 

### Notes;

The script now successfully builds *vulkan.turnip.so (Mesa 26.X.X)* for Android aarch64 on Linux Debian; and packages it into a Magisk module and adpkg, ready for installation on Adreno GPU devices. *Developer debug tools and GPU Cache disabled.*

When switching drivers - if experiencing crashes - clear driver shader cache(s)

`GA` is a release generally available to the public. Releases marked `DEVEL` are development builds, built from *Main* branch, who's build isn't "technically" available yet to the public. There may be times where Mesa3D releases a new development build to the public; Those releases will still be marked `GA` (or the latest stable release) as mesa is making the *`"Dev"`* build generally available to the public - a comment will be made in the notes section of the release. If there are two colliding version numbers only seperated by their `GA` and `DEVEL` notation, always choose the `GA` version - `GA` are always assumed to be more stable. `DEVEL` builds will have "cutting edge features" and the possibility of new title stability; while introducing the possibility of more bugs *and/or* bugs being introduced to previously stable titles. Once `DEVEL` is released `GA`, `GA` releases always supercede the `DEVEL` releases during times of version number collision - in feature and stability.

### **🔍 Summary of Changes & Fixes**

#### 1. Variable Scope: Fixed a bug where $MESASRC_DIR was used as an absolute path after cding into it, causing double-path errors. Switched to relative paths (src/...) inside the build function.

#### 2. Dependency Management (The "Host Library" Nightmare) 💀

- Host vs. Target Mismatch: The linker kept trying to link against x86_64 host libraries (/usr/lib/x86_64-linux-gnu/libz.so, libelf.so) instead of the aarch64 NDK libraries.

- Fix: Added sed commands to strip these explicit host paths from the generated build.ninja file.

- Missing libz (Zlib): Disabling zlib caused "undefined symbol" errors (gzopen, deflate, etc.) because parts of the code still called these functions.

- Fix: Created custom C stubs (zlib_stubs.c) that provide empty implementations of all gz* functions. Compiled these into a static library (libz_stub.a) and injected it into the link command right before --end-group to satisfy the linker without needing the real library.

- Missing libdl: Meson couldn't find libdl in the cross-compile environment.

- Fix: Added -ldl explicitly to the linker arguments, relying on the NDK's libc which provides these symbols on Android.

 #### 3. Feature Disabling for Stability ❗

- To bypass complex dependencies that are impossible to resolve cleanly in a cross-compile environment, deliberately disabled non-essential features:

-Dshader-cache=disabled: Prevented the build from requiring zlib for shader caching. (Trade-off: Slightly longer initial game load times after reboot, but no runtime stutter).

-Dzlib=disabled & -Dzstd=disabled: Removed the need for real compression libraries. `*Dzstd Re-enabled*`

-Dspirv-tools=disabled: Avoided header path conflicts with the system spirv-tools.

-Dgallium-drivers=: Disabled the Gallium API (desktop OpenGL) to focus purely on the Vulkan driver, reducing build size and complexity.


#### 4. Build System Patches 🔨

- libfreedreno_drm Error: The perfcntrs/meson.build file referenced a variable that only exists when Gallium is enabled.
 
- Fix: Added a command to comment out whichever lines of src/freedreno/perfcntrs/meson.build that cause failure - *before running Meson* - by searching for the libfreedreeno_drm string. / Now more reliably patched by searching for and commenting out failure signatures only.
 
- Test Tool Failures: Debug tools like ir3_disasm and fd5_layout failed to link due to the host library issues.
 
- Fix: Created dummy empty files for these targets in the build directory so Ninja would skip the failed link step and proceed.

#### 5. Script Optimization & Cleanup 🔬

- Dynamic NDK Handling: Replaced hardcoded NDK paths with variables ($ndkver, $NDK_TOOLCHAIN) so the script works with different NDK versions (e.g., r27c or r26d).

- Redundancy Removal: Consolidated multiple sed patches into single, robust blocks. Removed failed fallback logic and duplicate commands.

- Magisk Packaging: Streamlined the port_lib_for_magisk function to correctly set permissions, sonames, and generate the update-binary and customize.sh scripts.

#### 6. Version-Agnostic / Meta Info 🔁

- Script now functions correctly regardless of pulled version / auto populates appropriately consistent naming convention for output zipped files, and meta/config info based upon the particular build.

### **📜 The "Magic" Flags Used**

The final meson setup command that made it all work:

-Dbuildtype=release \
-Dplatforms=android \
-Dandroid-stub=true \
-Dgallium-drivers= \
-Dvulkan-drivers=freedreno \
-Dvulkan-beta=true \
-Dfreedreno-kmds=kgsl \
-Dzstd=disabled \ *Re-enabled* \
-Dspirv-tools=disabled \
-Dzlib=disabled \
-Dshader-cache=disabled \
-Dc_link_args="-L$workdir/stub_libs -lz_stub -ldl"

### **🚀 Conclusion**

Downloads the NDK and Mesa source.
Patches the source code to remove incompatible features.
Generates custom stub libraries to fool the linker.
Builds the Vulkan driver.
Auto populates correct meta and other config info based on version.
Packages it into a flashable Magisk module following consistent naming convention.
Packages an ADPKG file ready for emulators, or for other Adreno GPU's by other root method access; following consistent naming convention.

### Tested with the apps/games listed [here](list.md). 🎮

#### Magisk Build:
- Ensure program is using Vulkan for best compatibility
- `else-OpenGL - Defaults to Vulkan driver for render via OpenGL_ES / (vulkan -> egl -> opengles)`

#### Emulation/Root adpkg
- For emulators, or other root level adpkg installs - software or firmware

#### To Build Locally
- Obtain the script [turnipbuilder.sh]
- Change Build Config section to your desired results. ie. *change line 20 **`BUILD_TYPE="DEV"`** between **`"DEV"`** and **`"STABLE"`** / DEV pulls from most recently published main dev build. STABLE pulls from the specific stable release url provided on line 28*
- Save and Run script on linux deb terminal `bash ./turnipbuilder.sh` - if script is in folder; right click in folder and `open in terminal` then run `bash` command in folder. Ensure no spaces in run folder/environment and use "_" or "-" instead of spaces.
- script will require >= 3.3gb of space for work_dir - depending on settings - work_dir can be deleted after exported zips are moved out of work_dir and installed

### ToDo: 
| Planned | Completed | Purpose |
| :---    | :---      | :---    |
| - Update script so that a readable, reasonable, consistent file naming convention is used | ✅ | Scipt stability feature |
| - Update script to include the auto population of approriate meta and config info to be auto zipped | ✅ | Scipt meta convention consistency feature |
| - Update script to include auto building .adpkg file so manual build isn't necessary (auto zip - contents only! - of both build folders -Magisk/ADPKG) | ✅ | Script ease of access feature |
| - Update script to make version-agnostic; functioning regardless of mesarc version pulled and making inclusive of all version folder paths used by differently named archives and builds | ✅ | Script compatibility feature |
| - Bump Vulkan to v1.4 / OpenGL to v4.6 | Auto | Script will auto populate in reporting programs when Vulkan 1.4 is standardized - ie. *Mesa3d repo header update* & *Vendors update their Vulkan Loader & System Libraries* to offer official support and system reporting - *No force flags used in compilation* / Gallium Driver ie. OpenGL for Desktop is disabled. |
| - Resolve complex dependency issues to enable shader cache and shader cache compression | zstd Re-Enabled / when - *if* Mesa devs translate over turnip shader cache to use zstd, so too will shader cache be re-enabled | Driver efficiency and performance |

### References

- https://gitlab.freedesktop.org/mesa/mesa/

- https://mesa3d.org/

- https://forum.xda-developers.com/t/getting-freedreno-turnip-mesa-vulkan-driver-on-a-poco-f3.4323871/

- https://gitlab.freedesktop.org/mesa/mesa/-/issues/6802

- https://github.com/bylaws/libadrenotools

- https://github.com/ilhan-athn7/freedreno_turnip-CI

- https://github.com/K11MCH1/freedreno_turnip-CI
