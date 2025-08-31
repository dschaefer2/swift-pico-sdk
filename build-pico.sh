set -ex

export TOOLCHAINS=org.swift.620202508211a

build_dir=$(pwd)/build
rm -fr ${build_dir}

sdk_dir=${build_dir}/pico.sdk
mkdir -p ${sdk_dir}

target_triple=armv8m.main-unknown-none-eabi
compile_flags="-mcpu=cortex-m33 -mfloat-abi=softfp -march=armv8m.main+fp+dsp"

cmake -S $(pwd)/llvm-project/compiler-rt \
    -B ${build_dir}/compiler-rt \
    -G Ninja \
    -DCMAKE_INSTALL_PREFIX=${sdk_dir} \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_SYSTEM_PROCESSOR=arm \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_COMPILER=$(xcrun -f clang) \
    -DCMAKE_C_COMPILER_TARGET=${target_triple} \
    -DCMAKE_C_FLAGS="${compile_flags}" \
    -DCMAKE_ASM_COMPILER=$(xcrun -f clang) \
    -DCMAKE_ASM_COMPILER_TARGET=${target_triple} \
    -DCMAKE_ASM_FLAGS="${compile_flags}" \
    -DCMAKE_AR=$(xcrun -f llvm-ar) \
    -DCMAKE_RANLIB=$(xcrun -f llvm-ranlib) \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCOMPILER_RT_OS_DIR=pico \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_BUILD_CRT=OFF

cmake --build ${build_dir}/compiler-rt -- install-builtins

export PATH=$(dirname $(xcrun -f clang)):$PATH

meson setup \
    --cross-file config/pico2-arm.txt \
    --prefix=${sdk_dir} \
    ${build_dir}/picolibc $(pwd)/picolibc

meson compile -C ${build_dir}/picolibc
meson install -C ${build_dir}/picolibc

exit

cmake -G Ninja \
  -S $(pwd)/llvm-project/runtimes \
  -B ${build_dir} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=$(pwd)/arm-none-eabi-toolchain.cmake \
  -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
  -DLLVM_ENABLE_PROJECTS="" \
  -DLLVM_TARGETS_TO_BUILD=ARM \
  -DLIBCXX_ENABLE_THREADS=OFF \
  -DLIBCXX_ENABLE_SHARED=OFF \
  -DLIBCXXABI_ENABLE_THREADS=OFF \
  -DLIBCXXABI_ENABLE_SHARED=OFF

cmake --build ${build_dir} -- runtimes-armv8m.main-none-eabi-install
