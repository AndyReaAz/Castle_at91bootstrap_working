// Copyright (C) 2026 Castle Group
//
// SPDX-License-Identifier: MIT

#ifndef __NEXTGEN_FUSE_H__
#define __NEXTGEN_FUSE_H__

enum nextgen_fuse_status {
	NEXTGEN_FUSE_OK = 0,
	NEXTGEN_FUSE_PROGRAMMED,
	NEXTGEN_FUSE_WRONG_SOC,
	NEXTGEN_FUSE_INCOMPATIBLE,
	NEXTGEN_FUSE_PROGRAM_FAILED,
	NEXTGEN_FUSE_VERIFY_FAILED,
};

#ifdef CONFIG_NEXTGEN_BOOT_FUSE_ENSURE
int nextgen_boot_fuse_ensure(void);
void nextgen_boot_fuse_report(int status);
#endif

#endif
