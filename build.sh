set -ex

export TOOLCHAINS=org.swift.620202508211a

build_dir=$(pwd)/build
rm -fr ${build_dir}

triple_pico2_arm=armv8m.main-unknown-none-eabi
cflags_pico2_arm="-mcpu=cortex-m33 -mfloat-abi=softfp -march=armv8m.main+fp+dsp"
proc_pico2_arm=arm

arches="pico2_arm"

for arch in ${arches}; do
    arch_dir=${build_dir}/${arch}
    sdk_dir=${arch_dir}/pico.sdk

    triplev=triple_${arch}
    triple=${!triplev}
    cflagsv=cflags_${arch}
    cflags=${!cflagsv}
    procv=proc_${arch}
    proc=${!procv}

    rm -fr ${arch_dir}
    mkdir -p ${arch_dir}

    cat > ${arch_dir}/toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR ${proc})
set(CMAKE_ASM_COMPILER_TARGET ${triple})
set(CMAKE_ASM_FLAGS "${cflags}")
set(CMAKE_C_COMPILER_TARGET ${triple})
set(CMAKE_C_FLAGS "${cflags}")
set(CMAKE_CXX_COMPILER_TARGET ${triple})
set(CMAKE_CXX_FLAGS "${cflags}")
set(CMAKE_SYSROOT ${sdk_dir})

set(CMAKE_CROSSCOMPILING=YES)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXE_LINKER_FLAGS "-unwindlib=libunwind -rtlib=compiler-rt -stdlib=libc++ -fuse-ld=lld -lc++ -lc++abi")

set(CMAKE_ASM_COMPILER $(xcrun -f clang))
set(CMAKE_C_COMPILER $(xcrun -f clang))
set(CMAKE_CXX_COMPILER $(xcrun -f clang++))
set(CMAKE_FIND_ROOT_PATH ${sdk_dir})
EOF

    cat > ${arch_dir}/toolchain.meson <<EOF
[binaries]
c = ['$(xcrun -f clang)', '--target=armv8m.main-unknown-none-eabi', '-mcpu=cortex-m33', '-mfloat-abi=softfp', '-march=armv8m.main+fp+dsp', '-nostdlib']
ar = '$(xcrun -f llvm-ar)'
strip = '$(xcrun -f strip)'
ranlib = '$(xcrun -f llvm-ranlib)'
ld = ['$(xcrun -f ld.lld)', '--target=armv8m.main-unknown-none-eabi', '-nostdlib']

[host_machine]
system = 'none'
cpu_family = 'arm'
cpu = 'cortex-m33'
endian = 'little'

[properties]
needs_exe_wrapper = true
skip_sanity_check = true
EOF

    meson setup \
	  --cross-file ${arch_dir}/toolchain.meson \
	  --prefix=${sdk_dir} \
	  ${arch_dir}/picolibc $(pwd)/picolibc

    meson compile -C ${arch_dir}/picolibc
    meson install -C ${arch_dir}/picolibc
    
    cmake -S $(pwd)/llvm-project/compiler-rt \
	  -B ${arch_dir}/compiler-rt \
	  -G Ninja \
	  --install-prefix ${sdk_dir} \
	  --toolchain ${arch_dir}/toolchain.cmake \
          -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
          -DCOMPILER_RT_BUILD_BUILTINS=ON \
          -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
          -DCOMPILER_RT_BUILD_MEMPROF=OFF \
          -DCOMPILER_RT_BUILD_PROFILE=OFF \
          -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
          -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
          -DCOMPILER_RT_BUILD_XRAY=OFF \
          -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
          -DCOMPILER_RT_BUILD_ORC=OFF \
	  -DCOMPILER_RT_BAREMETAL_BUILD=ON

    cmake --build ${arch_dir}/compiler-rt
    cmake --build ${arch_dir}/compiler-rt -- install

    cmake -S $(pwd)/llvm-project/runtimes \
	  -B ${arch_dir}/runtimes \
	  -G Ninja \
	  --install-prefix ${sdk_dir} \
	  --toolchain ${arch_dir}/toolchain.cmake \
          -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
          -DLLVM_PARALLEL_LINK_JOBS=1 \
          -DLIBUNWIND_ENABLE_SHARED=NO \
          -DLIBUNWIND_ENABLE_STATIC=YES \
          -DLIBUNWIND_ENABLE_THREADS=OFF \
	  -DLIBUNWIND_IS_BAREMETAL=ON \
          -DLIBCXXABI_ENABLE_SHARED=NO \
          -DLIBCXXABI_ENABLE_STATIC=YES \
          -DLIBCXXABI_USE_LLVM_UNWINDER=YES \
          -DLIBCXXABI_USE_COMPILER_RT=YES \
	  -DLIBCXXABI_ENABLE_THREADS=OFF \
	  -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
	  -DLIBCXX_ENABLE_FILESYSTEM=OFF \
          -DLIBCXX_ENABLE_SHARED=OFF \
          -DLIBCXX_ENABLE_STATIC=ON \
          -DLIBCXX_USE_COMPILER_RT=YES \
          -DLIBCXX_ENABLE_THREADS=OFF \
          -DLIBCXX_INCLUDE_BENCHMARKS=NO \
          -DLIBCXX_CXX_ABI=libcxxabi

        cmake --build ${arch_dir}/runtimes
	cmake --build ${arch_dir}/runtimes -- install

done
