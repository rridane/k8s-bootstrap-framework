package main

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Pipeline persiste, PAR CIBLE, les étapes réellement actives de chaque phase
// (verbe -> steps ordonnés). Fichier optionnel : <dossier-inventaire>/pipeline.yaml
//
//	prepare:   [time, netplan, etc_hosts, network_rules, swap, cli_tools]
//	configure: [rke2_cilium, rke2_kubevip]
//	bootstrap: [rke2_primary, rke2_servers, rke2_agents]
//	upgrade:   [kubeadm_prepare, kubeadm_control_plane, kubeadm_nodes]
//
// `cluster phase <verbe> <cible>` ne joue QUE ces étapes (via --tags sur l'agrégateur
// routé). Absent => la phase retombe sur l'agrégateur déclaré dans cluster.yaml.
type Pipeline map[string][]string

const pipelineFile = "pipeline.yaml"

// LoadPipeline lit <invDir>/pipeline.yaml. Absent => (nil, nil) : pas une erreur.
func LoadPipeline(invDir string) (Pipeline, error) {
	path := filepath.Join(invDir, pipelineFile)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("lecture pipeline %s : %w", path, err)
	}
	var p Pipeline
	if err := yaml.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("parsing pipeline %s : %w", path, err)
	}
	return p, nil
}

// Tags construit les tags complets "verbe:step" d'une phase, dans l'ordre déclaré.
// Sûr sur un Pipeline nil (renvoie une liste vide).
func (p Pipeline) Tags(verb string) []string {
	steps := p[verb]
	tags := make([]string, 0, len(steps))
	for _, s := range steps {
		tags = append(tags, verb+":"+s)
	}
	return tags
}
