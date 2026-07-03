# Build ImmortalWrt for Ruijie X30E Pro and X60 New

<br>

ImmortalWrt 25.12 with MTK HNAT enabled  
- build from source: https://github.com/chasey-dev/immortalwrt-mt798x-rebase  
<br>

Vanilla OpenWrt/ImmortalWrt  
- build via `Image Builder`: https://downloads.openwrt.org , https://downloads.immortalwrt.org  

<br><br>

## Vanilla ImmortalWrt Basic Build Steps
Install dependencies for Ubuntu 24.04
```bash
sudo apt update
sudo apt install -y build-essential libncurses5-dev zlib1g-dev \
file wget gawk git gettext libssl-dev xsltproc rsync unzip \
python3 python3-setuptools u-boot-tools
```

Download the `Image Builder`
```bash
download_site=https://downloads.immortalwrt.org
imfile=immortalwrt-imagebuilder-25.12.0-mediatek-filogic.Linux-x86_64.tar.zst
downloadurl=${download_site}/releases/25.12.0/targets/mediatek/filogic/${imfile}
wget -O - ${downloadurl} | tar --zstd -xf - 
mv *imagebuilder*-x86_64 builder
cd builder
```

Add build target into `builder/target/linux/mediatek/image/filogic.mk`  
Add board profile into `builder/.targetinfo`  
Add board specific files to `builder/files/`  
Copy board dtb to `builder/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/`  
- renamed as `image-mt7986a-ruijie-rg-x60-new-ubi.dtb`  

<br>

`kernel.bin` has to be created manually  
```bash
kerneldir=build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic
staging_dir/host/bin/gzip -f -9 -n -c $kerneldir/Image > $kerneldir/ruijie_rg-x60-new-ubi-kernel.bin
```

Build the firmware  
```bash
make image \
PROFILE="ruijie_rg-x60-new-ubi" \
FILES="files" \
PACKAGES="apk apk1 -apk2 -apk3"
```
The firmware image will be located in `bin/targets/mediatek/filogic/`.  

<br><br>

## Build from Source
Install requirements for Ubuntu 24.04
```bash
sudo apt update

sudo apt install -y build-essential clang flex bison g++ gawk \
gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
python3-setuptools rsync swig unzip zlib1g-dev file wget curl
```
Clone the source code
```bash
git clone -b 25.12 --single-branch --filter=blob:none \
https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git immortalwrt

git clone --depth 1 https://github.com/wn2try/build-immortalwrt-mt798x.git mt798x

cd immortalwrt
```
Update the feeds
```bash
./scripts/feeds update -a
./scripts/feeds install -a
```
Configure the firmware build
```bash
cp ../mt798x/diffconfig/mt7981-ruijie-x30e-pro_diffconfig .config
make defconfig
```
Copy user files to `<buildroot>`
```bash
cp -r ../mt798x/files ./
```
Build the firmware
```bash
make -j$(nproc) || make -j1 V=s
```
The firmware image will be located in `bin/targets/mediatek/filogic/`.  
<br>  

Use [hanwckf's u-boot](https://github.com/hanwckf/bl-mt798x) or [yuzhii's variant](https://github.com/Yuzhii0718/bl-mt798x-dhcpd) to flash the `factory` or `sysupgrade` image for the first time, `sysupgrade` can be used for upgrading later on.  
<br><br>

## Regarding the UBI layout
`fip`(`u-boot`) is stored in a static UBI volume, which requires `bl2` to be built with full-UBI support (UBI=1).  
Note that this `bl2` is unable to load `fip` from a mtd partition.  

<br>  

MTD layout of X60 New (UBI):  
| mtd          | size    |
| ------------ | ------- |
| BL2          | 1024k   |
| u-boot-env   | 512k    |
| Factory      | 2048k   |
| FIP          | 2048k   |
| product_info | 512k    |
| kdump        | 512k    |
| ubi          | 124416k |

<br>  

UBI (124416k) volumes:  
| name         | type    | size   |
| ------------ | ------- | ------ |
| factory      | static  | 124KiB |
| product_info | static  | 124KiB |
| fip          | static  | 2MiB   |
| ubootenv     | dynamic | 124KiB |
| ubootenv2    | dynamic | 124KiB |
| fit          | dynamic |        |

<br><br>

### X60 New (UBI) Flash Instructions  

<br>

Load `initramfs` image from u-boot via `TFTP` or `Web failsafe`.  

<br>

Login to the device via `SSH`.  
Ensure that the device has the same mtd layout as follows:  
```
root@ImmortalWrt:~# cat /proc/mtd
dev:    size   erasesize  name
mtd0: 00100000 00020000 "BL2"
mtd1: 00080000 00020000 "u-boot-env"
mtd2: 00200000 00020000 "Factory"
mtd3: 00200000 00020000 "FIP"
mtd4: 00080000 00020000 "product_info"
mtd5: 00080000 00020000 "kdump"
mtd6: 07980000 00020000 "ubi"
```

<br>

Upload the following files to device `/root` directory.  
- `x60-new-ubi-preloader.bin`
- `x60-new-ubi-bl31-uboot.fip`
- `x60-new-ubi-squashfs-sysupgrade.itb`

<br>

Run the following commands to create the UBI volumes:  
```bash
dd if=/dev/mtd2 of=/root/factory_4k.bin bs=4096 count=1
dd if=/dev/mtd4 of=/root/product_info_1k.bin bs=1024 count=1

ubidetach -p /dev/mtd6
ubiformat /dev/mtd6
ubiattach -p /dev/mtd6
# ubinfo -a

ubimkvol /dev/ubi0 -t static -N factory -s 124KiB
ubimkvol /dev/ubi0 -t static -N product_info -s 124KiB
ubimkvol /dev/ubi0 -t static -N fip -s 2MiB
ubimkvol /dev/ubi0 -N ubootenv -s 124KiB
ubimkvol /dev/ubi0 -N ubootenv2 -s 124KiB
# ubinfo -a

ubiupdatevol /dev/ubi0_0 /root/factory_4k.bin
ubiupdatevol /dev/ubi0_1 /root/product_info_1k.bin
ubiupdatevol /dev/ubi0_2 /root/x60-new-ubi-bl31-uboot.fip
# ubinfo -a
```

<br>

Replace `bl2`:  
```bash
# insmod mtd-rw i_want_a_brick=1
mtd erase BL2
mtd write /root/x60-new-ubi-preloader.bin BL2
```

<br>

Flash the sysupgrade image:  
```bash
sysupgrade -n /root/x60-new-ubi-squashfs-sysupgrade.itb
```

<br>

Device automatically reboots itself, wait until it comes back online.  

<br><br>
