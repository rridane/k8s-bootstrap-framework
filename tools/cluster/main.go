// cluster — runner du framework de création de clusters.
//
// Une étape est jouée via SON fichier catalog (sortie silencieuse) ; un tag qui
// couvre plusieurs fichiers retombe sur l'agrégateur. Flux façon Terraform :
// plan (--check --diff) -> confirmation -> apply. `--force` applique directement.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

const configFile = "cluster.yaml"

func main() {
	if err := rootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "cluster: "+err.Error())
		os.Exit(1)
	}
}

func rootCmd() *cobra.Command {
	var force bool
	root := &cobra.Command{
		Use:               "cluster <tag> <inventaire> [args ansible...]",
		Short:             "Runner du framework (plan -> confirmation -> apply).",
		Args:              cobra.MinimumNArgs(2),
		ValidArgsFunction: completeTagThenInventory,
		SilenceUsage:      true,
		SilenceErrors:     true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runTag(args[0], args[1], args[2:], force)
		},
	}
	root.Flags().SetInterspersed(false) // tout ce qui suit le tag part vers ansible
	root.Flags().BoolVar(&force, "force", false, "applique directement, sans plan ni confirmation")
	root.AddCommand(listCmd(), phaseCmd())
	return root
}

// runTag joue une étape : per-fichier si possible, sinon agrégateur.
func runTag(tag, inventory string, passthrough []string, force bool) error {
	cfg, err := LoadConfig(configFile)
	if err != nil {
		return err
	}
	cat, err := ScanCatalog(cfg.CatalogDir)
	if err != nil {
		return err
	}
	if popped, rest := popFlags(passthrough, "--force", "-f"); popped {
		force = true
		passthrough = rest
	}
	playbook, err := resolvePlaybook(cfg, cat, tag)
	if err != nil {
		return err
	}
	if err := requireInventory(inventory); err != nil {
		return err
	}
	base := []string{"-i", inventory, playbook, "-t", tag}
	return executePlanApply(base, passthrough, force)
}

// resolvePlaybook : 1 fichier catalog -> lui (silencieux) ; sinon agrégateur.
func resolvePlaybook(cfg *Config, cat *Catalog, tag string) (string, error) {
	files := cat.FilesFor(tag)
	switch {
	case len(files) == 1:
		return files[0], nil
	case len(files) > 1:
		if pb, ok := cfg.Route(tag); ok {
			return pb, nil
		}
		return "", fmt.Errorf("tag %q présent dans %d fichiers et aucune route agrégateur", tag, len(files))
	default:
		if pb, ok := cfg.Route(tag); ok {
			return pb, nil
		}
		return "", fmt.Errorf("tag inconnu %q — voir `cluster list`", tag)
	}
}

// executePlanApply : --check (plan seul) / --force (apply direct) / plan->confirm->apply.
func executePlanApply(base, passthrough []string, force bool) error {
	if contains(passthrough, "--check", "-C") {
		return ansible(concat(base, passthrough))
	}
	if force {
		fmt.Println("── apply (--force) ──")
		return ansible(concat(base, concat([]string{"--diff"}, passthrough)))
	}
	fmt.Println("── plan (--check --diff) ──")
	if err := ansible(concat(base, concat([]string{"--check", "--diff"}, passthrough))); err != nil {
		fmt.Fprintln(os.Stderr, "note: le plan (--check) peut faussement échouer sur les séquences install→configure.")
	}
	if !confirm("Appliquer ces changements ?") {
		fmt.Println("Annulé.")
		return nil
	}
	fmt.Println("── apply ──")
	return ansible(concat(base, concat([]string{"--diff"}, passthrough)))
}

func listCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "Liste les tags par étape (dérivés du catalog)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := LoadConfig(configFile)
			if err != nil {
				return err
			}
			cat, err := ScanCatalog(cfg.CatalogDir)
			if err != nil {
				return err
			}
			printList(cat)
			return nil
		},
	}
}

func phaseCmd() *cobra.Command {
	var force bool
	c := &cobra.Command{
		Use:               "phase <nom> <inventaire> [args ansible...]",
		Short:             "Joue une phase entière via son agrégateur (prepare, clean, bootstrap-rke2...)",
		Args:              cobra.MinimumNArgs(2),
		ValidArgsFunction: completePhaseThenInventory,
		SilenceUsage:      true,
		SilenceErrors:     true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := LoadConfig(configFile)
			if err != nil {
				return err
			}
			ph, ok := cfg.Phases[args[0]]
			if !ok {
				return fmt.Errorf("phase inconnue %q (voir cluster.yaml)", args[0])
			}
			passthrough := args[2:]
			if popped, rest := popFlags(passthrough, "--force", "-f"); popped {
				force = true
				passthrough = rest
			}
			if err := requireInventory(args[1]); err != nil {
				return err
			}
			base := []string{"-i", args[1], ph.Playbook}
			if ph.Tag != "" {
				base = append(base, "-t", ph.Tag)
			}
			return executePlanApply(base, passthrough, force)
		},
	}
	c.Flags().SetInterspersed(false)
	c.Flags().BoolVar(&force, "force", false, "applique directement, sans plan ni confirmation")
	return c
}

// ── helpers ──

func ansible(args []string) error {
	fmt.Println("+ ansible-playbook " + strings.Join(args, " "))
	cmd := exec.Command("ansible-playbook", args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func requireInventory(inv string) error {
	if _, err := os.Stat(inv); err != nil {
		return fmt.Errorf("inventaire introuvable : %q — donne un chemin (ex. inventories/rke2-ovh/host.ini)", inv)
	}
	return nil
}

func printList(cat *Catalog) {
	hasClean := map[string]bool{}
	var prep, rke2, kubeadm []string
	for _, t := range cat.Tags() {
		switch {
		case strings.HasPrefix(t, "prepare:"):
			prep = append(prep, strings.TrimPrefix(t, "prepare:"))
		case strings.HasPrefix(t, "clean:"):
			hasClean[strings.TrimPrefix(t, "clean:")] = true
		case strings.HasPrefix(t, "bootstrap:rke2_"), strings.HasPrefix(t, "configure:rke2_"):
			rke2 = append(rke2, t)
		case strings.HasPrefix(t, "bootstrap:kubeadm_"):
			kubeadm = append(kubeadm, t)
		}
	}
	fmt.Println("── prépa  (prepare:<x> · clean:<x>) ──")
	for _, s := range prep {
		if hasClean[s] {
			fmt.Printf("  %-26s %s\n", "prepare:"+s, "clean:"+s)
		} else {
			fmt.Printf("  prepare:%s\n", s)
		}
	}
	printGroup("bootstrap RKE2", rke2)
	printGroup("bootstrap kubeadm", kubeadm)
}

func printGroup(title string, tags []string) {
	if len(tags) == 0 {
		return
	}
	fmt.Println("── " + title + " ──")
	for _, t := range tags {
		fmt.Println("  " + t)
	}
}

func confirm(prompt string) bool {
	fmt.Printf("\n%s  [yes/no] ", prompt)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return false
	}
	return equalAny(strings.TrimSpace(strings.ToLower(line)), "yes", "y", "oui", "o")
}

func equalAny(s string, opts ...string) bool {
	for _, o := range opts {
		if s == o {
			return true
		}
	}
	return false
}

func contains(args []string, flags ...string) bool {
	for _, a := range args {
		if equalAny(a, flags...) {
			return true
		}
	}
	return false
}

func popFlags(args []string, flags ...string) (found bool, rest []string) {
	for _, a := range args {
		if equalAny(a, flags...) {
			found = true
			continue
		}
		rest = append(rest, a)
	}
	return found, rest
}

func concat(a, b []string) []string {
	out := make([]string, 0, len(a)+len(b))
	return append(append(out, a...), b...)
}

// ── complétion shell ──

func completeTagThenInventory(cmd *cobra.Command, args []string, toComplete string) ([]string, cobra.ShellCompDirective) {
	cfg, err := LoadConfig(configFile)
	if err != nil {
		return nil, cobra.ShellCompDirectiveError
	}
	switch len(args) {
	case 0: // le tag
		cat, err := ScanCatalog(cfg.CatalogDir)
		if err != nil {
			return nil, cobra.ShellCompDirectiveError
		}
		return withPrefix(cat.Tags(), toComplete), cobra.ShellCompDirectiveNoFileComp
	case 1: // l'inventaire
		return inventoryCandidates(cfg, toComplete), cobra.ShellCompDirectiveNoFileComp
	default:
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
}

func completePhaseThenInventory(cmd *cobra.Command, args []string, toComplete string) ([]string, cobra.ShellCompDirective) {
	cfg, err := LoadConfig(configFile)
	if err != nil {
		return nil, cobra.ShellCompDirectiveError
	}
	switch len(args) {
	case 0:
		names := make([]string, 0, len(cfg.Phases))
		for n := range cfg.Phases {
			names = append(names, n)
		}
		return withPrefix(names, toComplete), cobra.ShellCompDirectiveNoFileComp
	case 1:
		return inventoryCandidates(cfg, toComplete), cobra.ShellCompDirectiveNoFileComp
	default:
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
}

func inventoryCandidates(cfg *Config, toComplete string) []string {
	entries, err := os.ReadDir(cfg.InventoriesDir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), "_") {
			out = append(out, filepath.Join(cfg.InventoriesDir, e.Name(), cfg.InventoryFile))
		}
	}
	return withPrefix(out, toComplete)
}

func withPrefix(items []string, prefix string) []string {
	if prefix == "" {
		return items
	}
	var out []string
	for _, s := range items {
		if strings.HasPrefix(s, prefix) {
			out = append(out, s)
		}
	}
	return out
}
