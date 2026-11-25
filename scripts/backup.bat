@echo off
rem Full backup of an Infimech TX V2 before changing anything.
rem Run in cmd (not PowerShell), in an empty folder with ~6 GB free.
rem Edit the next line first. Every ssh line asks for the root password.
set PRINTER=<PRINTER_IP>

rem eMMC partitions 1-5 and the two boot areas, as raw images
for %%p in (1 2 3 4 5) do ssh root@%PRINTER% "dd if=/dev/mmcblk0p%%p bs=64k" > p%%p.img
ssh root@%PRINTER% "dd if=/dev/mmcblk0boot0 bs=64k" > boot0.img
ssh root@%PRINTER% "dd if=/dev/mmcblk0boot1 bs=64k" > boot1.img

rem /server (partition 6: the Debian system and the vendor files) as a tar
ssh root@%PRINTER% "tar -C /server --exclude=./tmp/proc --exclude=./tmp/sys --exclude=./tmp/dev --exclude=./tmp/run -cf - ." > server.tar

rem checksums: the printer's and the PC's must match line by line
ssh root@%PRINTER% "md5sum /dev/mmcblk0p1 /dev/mmcblk0p2 /dev/mmcblk0p3 /dev/mmcblk0p4 /dev/mmcblk0p5 /dev/mmcblk0boot0 /dev/mmcblk0boot1" > md5_printer.txt
(for %%f in (p1.img p2.img p3.img p4.img p5.img boot0.img boot1.img) do certutil -hashfile %%f MD5 | findstr /v ":") > md5_pc.txt
tar -tf server.tar > nul && echo server.tar reads OK
echo Compare md5_printer.txt with md5_pc.txt (same order).
