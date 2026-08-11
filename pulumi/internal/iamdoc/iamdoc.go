// Package iamdoc builds IAM policy documents.
//
// Terraform used the aws_iam_policy_document data source for this, which
// rendered JSON by making a call to the provider. Here the documents are marshalled
// in-process: a policy is a value rather than a resource graph node, so nothing
// has to wait on it and a typo is a compile error rather than an apply-time one.
//
// A document whose resources are created in the same run is built inside an
// apply over their ARNs. That is the normal case for the task policies.
package iamdoc

import (
	"encoding/json"
	"fmt"
)

// Document is an IAM policy document. The version is fixed: 2012-10-17 is the
// only value any statement in this project relies on.
type Document struct {
	Version    string      `json:"Version"`
	Statements []Statement `json:"Statement"`
}

// Statement is one statement of a policy. Effect defaults to Allow when empty,
// matching aws_iam_policy_document, which this project never overrode.
type Statement struct {
	Sid       string               `json:"Sid,omitempty"`
	Effect    string               `json:"Effect"`
	Actions   []string             `json:"Action,omitempty"`
	Resources []string             `json:"Resource,omitempty"`
	Principal *Principal           `json:"Principal,omitempty"`
	Condition map[string]Condition `json:"Condition,omitempty"`
}

// Principal names who a statement applies to. Only service principals appear in
// this project, so there is one field.
type Principal struct {
	Service []string `json:"Service,omitempty"`
}

// Condition is a condition operator's set of keys and values, e.g.
// {"kms:ViaService": ["ssm.us-east-2.amazonaws.com"]}.
type Condition map[string][]string

// New returns a document holding the given statements, filling in the version
// and defaulting each effect to Allow.
func New(statements ...Statement) Document {
	for index, statement := range statements {
		if statement.Effect == "" {
			statements[index].Effect = "Allow"
		}
	}

	return Document{Version: "2012-10-17", Statements: statements}
}

// JSON renders the document.
func (d Document) JSON() (string, error) {
	encoded, err := json.Marshal(d)
	if err != nil {
		return "", fmt.Errorf("marshal policy document: %w", err)
	}

	return string(encoded), nil
}

// MustJSON renders a document that cannot fail to marshal, for the static
// documents built from string literals. Every field is a string, a slice of
// strings or a map of them, so json.Marshal has nothing to reject; a panic here
// would be a bug in this package rather than bad configuration.
func (d Document) MustJSON() string {
	encoded, err := d.JSON()
	if err != nil {
		panic(err)
	}

	return encoded
}

// AssumeRole returns a trust policy letting an AWS service assume the role,
// replacing the assume-role document each module declared for itself.
func AssumeRole(service string) string {
	return New(Statement{
		Actions:   []string{"sts:AssumeRole"},
		Principal: &Principal{Service: []string{service}},
	}).MustJSON()
}
