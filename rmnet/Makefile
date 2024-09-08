# Copyright (c) 2024, Qualcomm Innovation Center, Inc. All rights reserved.
# SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

obj-m += GobiNet.o
GobiNet-objs := qmap.o GobiUSBNet.o QMIDevice.o QMI.o

OS_RELEASE = $(shell cat /etc/os-release | grep PRETTY_NAME)

ifneq (,$(findstring Red Hat Enterprise Linux,$(OS_RELEASE)))
EXTRA_CFLAGS += -DQCUSB_RHEL
endif

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
