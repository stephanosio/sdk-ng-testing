#!/bin/bash

TARGETS=${@}

if [ -z "$TARGETS" ]; then
	echo "Please specify target"
	exit 1
fi

GITDIR=${PWD}
TARBALL_DIR=${GITDIR}
JOBS=$(python -c 'import multiprocessing as mp; print(mp.cpu_count())')

unameOut="$(uname -s)"
machine="$(uname -m)"
case "${unameOut}" in
    Linux*)     os=linux;;
    Darwin*)    os=macos;;
    CYGWIN*)    os=cygwin;;
    MINGW*)     os=mingw;;
    *)          os="UNKNOWN:${unameOut}"
esac

SDK_NG_HOME=${PWD}
if [ "$os" == "macos" ]; then
	ImageName=CrossToolNGNew
	ImageNameExt=${ImageName}.sparseimage
	SDK_NG_HOME="/Volumes/${ImageName}"
fi

CROSSTOOL_COMMIT="330f634fa6489758ce50b103a0cda3a7448209c9"
build_crosstool()
{
	# only build if we don't already have a built binary
	if [ ! -x "${SDK_NG_HOME}/bin/ct-ng" ]; then
		if [ "$os" == "macos" ]; then
			if [ -x "/opt/homebrew/bin/brew" ]; then
				export HOMEBREW_ROOT="/opt/homebrew"
			elif [ -x "/usr/local/bin/brew" ]; then
				export HOMEBREW_ROOT="/usr/local"
			else
				echo "No brew install found"
				exit 1
			fi

			brew install autoconf automake bash binutils gawk gnu-sed gnu-tar help2man ncurses xz libtool

			export PATH="$PATH:${HOMEBREW_ROOT}/opt/binutils/bin"
			export CPPFLAGS="-I${HOMEBREW_ROOT}/opt/ncurses/include -I${HOMEBREW_ROOT}/opt/gettext/include"
			export LDFLAGS="-L${HOMEBREW_ROOT}/opt/ncurses/lib -L${HOMEBREW_ROOT}/opt/gettext/lib"

			macos_setup_diskimage
		fi

		# Checkout crosstool-ng if we haven't already
		if [ ! -d "${SDK_NG_HOME}/crosstool-ng" ]; then
			pushd ${SDK_NG_HOME}
			git clone https://github.com/zephyrproject-rtos/crosstool-ng.git
			pushd crosstool-ng
			git checkout ${CROSSTOOL_COMMIT}
			popd
			popd
		fi

		pushd ${SDK_NG_HOME}/crosstool-ng
		./bootstrap
		CFLAGS="-DKBUILD_NO_NLS" ./configure --prefix=${SDK_NG_HOME}
		make && make install
		popd

		tar -jcvf ${TARBALL_DIR}/${t}.${os}.${machine}.tar.bz2 -C ${SDK_NG_HOME} bin libexec share
	fi
}

macos_setup_diskimage()
{
	if [ ! -e "$ImageNameExt" ]; then
		diskutil umount force ${SDK_NG_HOME} && true
		rm -f ${ImageNameExt} && true
		hdiutil create ${ImageName} -volname ${ImageName} -type SPARSE -size 64g -fs HFSX
	fi
	if [ ! -d ${SDK_NG_HOME} ]; then
		hdiutil mount ${ImageNameExt}
	fi
}

CT_NG=${SDK_NG_HOME}/bin/ct-ng

for t in ${TARGETS}; do
	if [ "${t}" = "tools" ]; then
		${GITDIR}/meta-zephyr-sdk/scripts/meta-zephyr-sdk-clone.sh
		${GITDIR}/meta-zephyr-sdk/scripts/meta-zephyr-sdk-build.sh tools
		mv ${GITDIR}/meta-zephyr-sdk/scripts/toolchains/zephyr-sdk-${machine}-hosttools-standalone-0.9.sh ${TARBALL_DIR}
		exit $?
	elif [ "${t}" = "cmake" ]; then
		tar -jcvf ${TARBALL_DIR}/${t}.${os}.${machine}.tar.bz2 -C ${GITDIR} cmake
		exit $?
	elif [ "${t}" = "crosstool" ]; then
		build_crosstool
		exit $?
	elif [ "${t}" = "macos_setup_diskimage" ]; then
		macos_setup_diskimage
		exit $?
	fi
done

# prep
cp -a ${GITDIR}/patches-arc64 ${SDK_NG_HOME} 2>/dev/null

OUTPUT_DIR=${SDK_NG_HOME}/build/output

mkdir -p ${OUTPUT_DIR}/sources

for t in ${TARGETS}; do
	if [ "${t}" = "tools" ]; then
		# We handled tools above, so skip it here
		continue
	elif [ "${t}" = "cmake" ]; then
		# We handled cmake above, so skip it here
		continue
	fi
	if [ ! -f ${GITDIR}/configs/${t}.config ]; then
		echo "Target configuration does not exist"
		exit 1
	fi

	build_crosstool

	echo "Building ${t}"
	TARGET_BUILD_DIR=${SDK_NG_HOME}/build/build_${t}
	mkdir -p ${TARGET_BUILD_DIR}
	pushd ${TARGET_BUILD_DIR}

	export CT_PREFIX=${OUTPUT_DIR}
	TARGET_DIR=""
	case "${t}" in
		xtensa_*)
			cp -a ${GITDIR}/overlays ${TARGET_BUILD_DIR}
			TRIPLET=xtensa-zephyr-elf
			TARGET_DIR="xtensa/${t#xtensa_}/"
			export CT_PREFIX=${OUTPUT_DIR}/${TARGET_DIR}
			mkdir -p ${CT_PREFIX}
			;;
		x86_64-zephyr-elf)
			TRIPLET="x86_64-zephyr-elf"
			;;
		arm64)
			TRIPLET="aarch64-zephyr-elf"
			;;
		arm)
			TRIPLET="arm-zephyr-eabi"
			;;
		*)
			TRIPLET="${t}-zephyr-elf"
			;;
	esac

	${CT_NG} clean
	cp ${GITDIR}/configs/${t}.config ${TARGET_BUILD_DIR}/defconfig

	# Disable python support in GDB on MacOS, this isn't currently working.
	# It builds ok, but the resulting GDB segfaults.
	if [ "$os" == "macos" ]; then
		sed -i -e '/CT_GDB_CROSS_PYTHON_BINARY/d' defconfig
		sed -i -e '/CT_GDB_CROSS_BUILD_NO_PYTHON/d' defconfig
		sed -i -e '/^CT_CC_GCC_EXTRA_CONFIG_ARRAY=/ s/"$/ --without-zstd"/' defconfig
		echo "# CT_GDB_CROSS_PYTHON is not set" >> defconfig
	fi

	${CT_NG} defconfig DEFCONFIG=${TARGET_BUILD_DIR}/defconfig
	${CT_NG} savedefconfig DEFCONFIG=${TARGET_BUILD_DIR}/${t}.config
	${CT_NG} build -j ${JOBS}
	if [ $? != 0 ]; then
		exit 1
	fi
	rm -rf ${CT_PREFIX}/*/newlib-nano

	popd
	rm -fr ${TARGET_BUILD_DIR}
	mv ${CT_PREFIX}/${TRIPLET}/build.log.bz2 ${OUTPUT_DIR}/build.${t}.${os}.${machine}.log.bz2
	tar -jcvf ${TARBALL_DIR}/${t}.${os}.${machine}.tar.bz2 -C ${OUTPUT_DIR} ${TARGET_DIR}${TRIPLET}
done
