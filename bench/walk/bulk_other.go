//go:build !darwin

package main

import "errors"

func scanBulk(root string, c *counts) error {
	return errors.New("getattrlistbulk needs macOS")
}
