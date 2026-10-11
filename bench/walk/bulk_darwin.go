package main

/*
#include <stdlib.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <unistd.h>
#include <fcntl.h>

static int bulk(int fd, void *buf, size_t size) {
	struct attrlist al = {0};
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME;
	al.fileattr = ATTR_FILE_DATALENGTH;
	return getattrlistbulk(fd, &al, buf, size, 0);
}
*/
import "C"

import (
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"
)

// Offsets in one getattrlistbulk(2) entry for the attributes asked for in
// bulk() above. getattrlist(2) says attributes come in bitmap order:
// u_int32_t length, attribute_set_t (5 x u_int32_t), attrreference_t name
// (2 x int32), fsobj_type_t (u_int32_t), struct timespec (16 bytes), then
// off_t ATTR_FILE_DATALENGTH, which is only present for files. Each
// attribute is aligned to 4 bytes, including 64-bit types.
const (
	offReturnedFile = 4 + 12 // attribute_set_t.fileattr
	offObjType      = 4 + 20 + 8
	offDataLength   = 4 + 20 + 8 + 4 + 16
)

// scanBulk walks the tree with getattrlistbulk(2), one call per batch of
// directory entries, with no per-file lstat.
func scanBulk(root string, c *counts) error {
	fd, err := syscall.Open(root, syscall.O_RDONLY|syscall.O_DIRECTORY, 0)
	if err != nil {
		return err
	}
	c.Dirs++
	buf := make([]byte, 256<<10)
	return bulkDir(fd, buf, c)
}

func bulkDir(fd int, buf []byte, c *counts) error {
	var subdirs []string
	for {
		n, err := C.bulk(C.int(fd), unsafe.Pointer(&buf[0]), C.size_t(len(buf)))
		if n < 0 {
			syscall.Close(fd)
			return fmt.Errorf("getattrlistbulk: %v", err)
		}
		if n == 0 {
			break
		}
		p := buf
		for i := 0; i < int(n); i++ {
			length := binary.LittleEndian.Uint32(p[0:])
			e := p[:length]
			nameOff := int32(binary.LittleEndian.Uint32(e[24:]))
			nameLen := binary.LittleEndian.Uint32(e[28:])
			name := string(e[24+int(nameOff) : 24+int(nameOff)+int(nameLen)-1])
			switch binary.LittleEndian.Uint32(e[offObjType:]) {
			case C.VREG:
				c.Files++
				if binary.LittleEndian.Uint32(e[offReturnedFile:])&C.ATTR_FILE_DATALENGTH != 0 {
					c.Bytes += int64(binary.LittleEndian.Uint64(e[offDataLength:]))
				}
			case C.VDIR:
				c.Dirs++
				subdirs = append(subdirs, name)
			case C.VLNK:
				c.Symlinks++
			default:
				c.Other++
			}
			p = p[length:]
		}
	}
	for _, name := range subdirs {
		sub, err := openat(fd, name)
		if err != nil {
			c.Errors++
			continue
		}
		// Recursion reuses one buffer: the names above are copied strings.
		if err := bulkDir(sub, buf, c); err != nil {
			syscall.Close(fd)
			return err
		}
	}
	return syscall.Close(fd)
}

func openat(dirfd int, name string) (int, error) {
	cs := C.CString(name)
	defer C.free(unsafe.Pointer(cs))
	fd, err := C.openat(C.int(dirfd), cs, C.O_RDONLY|C.O_DIRECTORY|C.O_NOFOLLOW)
	if fd < 0 {
		return -1, err
	}
	return int(fd), nil
}
