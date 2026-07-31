package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// tagRe capture les tags spécifiques "action:step" écrits dans les fichiers catalog.
// (les tags nus prepare/clean/bootstrap, sans ":", sont volontairement ignorés)
var tagRe = regexp.MustCompile(`(prepare|clean|bootstrap|configure):[a-z0-9_]+`)

// Catalog indexe tag -> fichiers du catalog qui le portent (source de vérité unique).
type Catalog struct {
	byTag map[string][]string
}

// ScanCatalog parcourt le dossier catalog et indexe les tags.
func ScanCatalog(dir string) (*Catalog, error) {
	c := &Catalog{byTag: map[string][]string{}}
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".yaml") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		seen := map[string]bool{}
		for _, tag := range tagRe.FindAllString(string(data), -1) {
			if seen[tag] {
				continue
			}
			seen[tag] = true
			c.byTag[tag] = append(c.byTag[tag], path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

// FilesFor renvoie les fichiers catalog portant ce tag.
func (c *Catalog) FilesFor(tag string) []string { return c.byTag[tag] }

// Tags renvoie tous les tags connus, triés.
func (c *Catalog) Tags() []string {
	out := make([]string, 0, len(c.byTag))
	for t := range c.byTag {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}
