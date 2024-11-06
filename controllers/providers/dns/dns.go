package dns

/*
Copyright 2022 The k8gb Contributors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Generated by GoLic, for more details see: https://github.com/AbsaOSS/golic
*/

import (
	k8gbv1beta1 "github.com/k8gb-io/k8gb/api/v1beta1"
	"github.com/k8gb-io/k8gb/controllers/providers/assistant"
	"sigs.k8s.io/controller-runtime/pkg/client"
	externaldns "sigs.k8s.io/external-dns/endpoint"
)

type Provider interface {
	// CreateZoneDelegationForExternalDNS handles delegated zone in Edge DNS
	CreateZoneDelegationForExternalDNS(*k8gbv1beta1.Gslb) error
	// GetExternalTargets retrieves list of external targets for specified host
	GetExternalTargets(string) assistant.Targets
	// SaveDNSEndpoint update DNS endpoint in gslb or create new one if doesn't exist
	SaveDNSEndpoint(*k8gbv1beta1.Gslb, *externaldns.DNSEndpoint) error
	// Finalize finalize gslb in k8gbNamespace
	Finalize(*k8gbv1beta1.Gslb, client.Client) error
	// String see: Stringer interface
	String() string
}
