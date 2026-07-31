package main

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config est le contenu de cluster.yaml.
type Config struct {
	CatalogDir     string           `yaml:"catalogDir"`
	InventoriesDir string           `yaml:"inventoriesDir"`
	InventoryFile  string           `yaml:"inventoryFile"`
	Routes         []Route          `yaml:"routes"`
	Phases         map[string]Phase `yaml:"phases"`
}

// Route associe un préfixe de tag à un playbook agrégateur (fallback).
type Route struct {
	Prefix   string `yaml:"prefix"`
	Playbook string `yaml:"playbook"`
}

// Phase joue un playbook entier, éventuellement restreint à un tag.
type Phase struct {
	Playbook string `yaml:"playbook"`
	Tag      string `yaml:"tag"`
}

// LoadConfig lit et parse cluster.yaml (avec valeurs par défaut).
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("lecture config %s : %w", path, err)
	}
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parsing config %s : %w", path, err)
	}
	if c.CatalogDir == "" {
		c.CatalogDir = "catalog"
	}
	if c.InventoriesDir == "" {
		c.InventoriesDir = "inventories"
	}
	if c.InventoryFile == "" {
		c.InventoryFile = "host.ini"
	}
	return &c, nil
}

// Route renvoie l'agrégateur routé pour un tag (premier préfixe qui matche).
func (c *Config) Route(tag string) (string, bool) {
	for _, r := range c.Routes {
		if strings.HasPrefix(tag, r.Prefix) {
			return r.Playbook, true
		}
	}
	return "", false
}
