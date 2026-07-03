#! /bin/bash
set -eu
#set -x


variant=${variant:-openwrt}
variant=${variant,,}
openwrtver=${openwrtver:-25.12.5}
openwrtver=${openwrtver,,}

model=${model:-x60-new-ubi}
model=${model,,}
vendor=${vendor:-ruijie}
vendor=${vendor,,}
device=${vendor}_rg-${model}

platform=${platform:-mediatek}
subtarget=${subtarget:-filogic}

pkgadd=${pkgadd:-}
pkgremove=${pkgremove:-}

firmwarenm=${variant}-${openwrtver}-${model}-squashfs-sysupgrade

initkernelsrc=mediatek-filogic-openwrt_one-initramfs.itb
initramfsnm=${variant}-${openwrtver}-${model}-initramfs

cd $(dirname "$0")
rootpath="$(pwd)"

builder_site=https://downloads.${variant}.org



## download imagebuilder
if [ ${openwrtver} = "snapshot" ]; then
  downloadurl=${builder_site}/snapshots/targets/${platform}/${subtarget}/${variant}-imagebuilder-${platform}-${subtarget}.Linux-x86_64.tar.zst
else
  downloadurl=${builder_site}/releases/${openwrtver}/targets/${platform}/${subtarget}/${variant}-imagebuilder-${openwrtver}-${platform}-${subtarget}.Linux-x86_64.tar.zst
fi

if [ ! -d builder ]; then
  echo "download imagebuilder..."
  wget -q -O imagebuilder.tar.zst ${downloadurl}
  tar --zstd -xf imagebuilder.tar.zst && rm imagebuilder.tar.zst
  mv *imagebuilder* builder
fi

cd builder

## add build target
echo -e "\nadd build target into makefile..."
basemodel=$(echo ${model} | sed -E 's/-ubi|-ubootmod//')
modeldir=${rootpath}/${basemodel}
makefile=${rootpath}/builder/target/linux/${platform}/image/${subtarget}.mk
sed "/${device}/,/${device}/d" -i ${makefile}
cat ${modeldir}/${model}.mk >> ${makefile}


## add board profile
echo -e "\nadd board profile into .targetinfo"
prof=${rootpath}/builder/.targetinfo
sed "/Target-Profile: DEVICE_${device}/,/@@/d" -i ${prof}

export profile=$(sed ':a; /\\$/ { N; s/\\\n//; ba }' ${modeldir}/${model}.mk | awk '
BEGIN {
    has_meta = 0
    pkg = ""
}
/define Device/ {
    model = $0;
    sub(/define Device.*_/, "", model);
    gsub(/[[:space:]]+/, "", model);
}
/:=/ {
    k = $1; v = $0;
    sub(/^.*:=/, "", v);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", k);
    gsub(/[[:space:]]+/, " ", v);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
    if (k == "DEVICE_VENDOR") vendor = v;
    if (k == "DEVICE_MODEL") devmodel = v;
    if (k == "DEVICE_PACKAGES") pkg = v;
}
/append-metadata/ { has_meta = 1 }
END {
    vendorl = tolower(vendor)
    printf "\nTarget-Profile: DEVICE_%s_%s\n", vendorl, model
    printf "Target-Profile-Name: %s %s\n", vendor, devmodel
    printf "Target-Profile-Packages: %s \n", pkg
    printf "Target-Profile-hasImageMetadata: %d\n", has_meta
    printf "Target-Profile-SupportedDevices: %s,%s\n\n\n", vendorl, model
    printf "Target-Profile-Description:\n"
    printf "Build firmware images for %s %s\n\n\n\n\n\n@@\n", vendor, devmodel
}')

awk -v p="Target: ${platform}/${subtarget}" \
' $0 == p {found=1; count=0} 
  found && /@@/ {count++} 1; 
  count==2 {print ENVIRON["profile"]; count=0; found=0}
' ${prof} > ${prof}.tmp && mv ${prof}.tmp ${prof}


## add files to include
echo -e "\nadd custom files..."
[ -d files ] && rm -rf files || true
cp -rf ${rootpath}/files .


## copy dtb to build dir
echo -e "\ncopy dtb to build dir..."
kerneldir=${rootpath}/builder/build_dir/target-aarch64_cortex-a53_musl/linux-${platform}_${subtarget}
dtbver=$(cd ${kerneldir}; ls -d linux-* | grep -oE '[6-9].[0-9]+')
dtbnm=$(cd ${modeldir}; ls *${model}.dts | sed 's/dts/dtb/')
cp ${modeldir}/*-${model}_${dtbver}.dtb ${kerneldir}/image-${dtbnm}


## create kernel.bin
echo -e "\ncreate kernel.bin..."
hostbindir=${rootpath}/builder/staging_dir/host/bin
kernelfile=${kerneldir}/${device}-kernel.bin
[ -e ${kernelfile} ] && rm -f ${kernelfile} || true
${hostbindir}/gzip -f -9 -n -c $kerneldir/Image > ${kernelfile}


## prepare output dir
[ -d _output ] && rm -rf _output || true
mkdir _output
outdir=${rootpath}/builder/_output


## build sysupgrade.itb
echo -e "\nbuild sysupgrade.itb..."

# apks
[[ "$pkgremove" ]] && ! $(echo "$pkgremove" | grep -qE '^-| -') && \
pkgremove=$(echo "$pkgremove" | sed "s/ / -/g; s/^/-/")

pkgpath=${rootpath}/apk/apk.${variant}
pkgadd1=$(sed -n '/^add:/ {s/add: //; p;}' ${pkgpath})
pkgremove1=$(sed -n '/^remove:/ {s/ / -/g; s/remove: //; p;}' ${pkgpath})

echo "pkgadd=${pkgadd} ${pkgadd1}"
echo "pkgremove=${pkgremove} ${pkgremove1}"

# build
make image \
PROFILE="${device}" \
FILES="files" \
BIN_DIR="${outdir}" \
PACKAGES="${pkgadd} ${pkgadd1} ${pkgremove} ${pkgremove1}"


## create initramfs.itb
echo -e "\nprepare initrd for initramfs..."
initrddir=${rootpath}/builder/build_dir/target-aarch64_cortex-a53_musl/root-${platform}
cp -fpR ${rootpath}/builder/target/linux/generic/other-files/init ${initrddir}/
(cd ${initrddir}; find . | LC_ALL=C sort | ${hostbindir}/cpio --reproducible -o -H newc -R 0:0 > ${outdir}/initrd.cpio)
${hostbindir}/xz -T0 -9 -fz --check=crc32 ${outdir}/initrd.cpio
rm -f ${initrddir}/init

echo -e "\nprepare kernel for initramfs..."
dumpimage -T flat_dt -p 0 -o ${outdir}/kernel.lzma \
${rootpath}/builder/staging_dir/target-aarch64_cortex-a53_musl/image/${initkernelsrc}

echo -e "\nprepare dtb for initramfs..."
if [ -e ${modeldir}/*${model}_initramfs.dtsi ]; then
  dtc -q -I dtb -O dts -o ${outdir}/initramfs.dts ${modeldir}/image-*-${model}_${dtbver}.dtb
  cat ${modeldir}/*${model}_initramfs.dtsi >> ${outdir}/initramfs.dts
  dtc -q -I dts -O dtb -o ${outdir}/initramfs.dtb ${outdir}/initramfs.dts
else
  cp ${modeldir}/image-*-${model}_${dtbver}.dtb ${outdir}/initramfs.dtb
fi

echo -e "\ncreate its for initramfs..."
kernelver=$(jq .linux_kernel.version ${outdir}/profiles.json | tr -d '"')
${rootpath}/builder/scripts/mkits.sh -D ${device} -c "config-1" \
-A arm64 -v ${kernelver} -C lzma -a 0x48000000 -e 0x48000000 \
-k ${outdir}/kernel.lzma \
-i ${outdir}/initrd.cpio.xz \
-d ${outdir}/initramfs.dtb \
-o ${outdir}/${initramfsnm}.its

echo -e "\ncreate initramfs itb..."
PATH=${kerneldir}/kernel-${kernelver}/scripts/dtc:$PATH \
${hostbindir}/mkimage -f ${outdir}/${initramfsnm}.its \
${outdir}/${initramfsnm}.itb


## create release outputs
echo -e "\ncreate final outputs..."
cd ${rootpath} && mkdir -p release && cd release
mv ${outdir}/*-${model}-squashfs-sysupgrade.itb ./${firmwarenm}.itb
mv ${outdir}/${initramfsnm}.itb .

gzip -1f ${firmwarenm}.itb
gzip -1f ${initramfsnm}.itb

mv ${outdir}/*${model}.manifest ./${variant}-${openwrtver}-${model}.manifest
mv ${outdir}/profiles.json ./${variant}-${openwrtver}-${model}-profiles.json

## the end
echo -e "\nfiles created:"
ls -lh ${rootpath}/release

echo -e "\nDone."
