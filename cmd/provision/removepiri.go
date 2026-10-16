package main

import (
	"context"
	"fmt"
	"log/slog"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"github.com/fil-forge/infra-central/internal/onboard"
)

// removePiriPhase removes one Piri from sprue, hilt's storage node set, the
// delegator's allow list and provider info, and central's record of its region.
//
// It is the way to move a Piri to a new URL, since onboarding refuses to change
// a registered Piri's endpoint: remove it here, then onboard it again with its
// proof. It is also the per-Piri half of evicting a node, which retire-region
// does not do.
//
// Like onboarding, it runs here because sprue's and hilt's admin APIs accept only
// invocations signed with their own keys. The caller is an operator running
// scripts/remove-piri.sh.
func (d *deps) removePiriPhase(ctx context.Context, req Request) (*Response, error) {
	if err := validateRemovePiriRequest(req); err != nil {
		return nil, err
	}
	if d.cfg.AllowListTable == "" {
		return nil, fmt.Errorf("FORGE_ALLOW_LIST_TABLE is required for the remove-piri phase")
	}
	if d.cfg.ProviderInfoTable == "" {
		return nil, fmt.Errorf("FORGE_PROVIDER_INFO_TABLE is required for the remove-piri phase")
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	dynamo := dynamodb.NewFromConfig(awsCfg)

	ingotDID, err := d.ingotDID(req.Region)
	if err != nil {
		return nil, err
	}

	sprueClient, hiltClient, _, err := d.adminClients(ctx)
	if err != nil {
		return nil, err
	}

	removeDeps := onboard.RemoveDeps{
		AllowList:    onboard.NewDynamoAllowList(dynamo, d.cfg.AllowListTable, d.cfg.Stage),
		Sprue:        sprueClient,
		Hilt:         hiltClient,
		ProviderInfo: onboard.NewDynamoProviderInfo(dynamo, d.cfg.ProviderInfoTable),
		PiriRecord:   &piriRecords{store: d.store},
	}
	removeReq := onboard.RemoveRequest{Region: req.Region, PiriDID: req.PiriDID, IngotDID: ingotDID}

	slog.Info("reading what sprue, hilt, the delegator and the region record hold",
		"region", req.Region, "piri", req.PiriDID, "ingot", ingotDID)
	state, err := onboard.ReadRemoval(ctx, removeDeps, removeReq)
	if err != nil {
		return nil, err
	}

	plan := onboard.PlanRemoval(state, removeReq)

	if !req.Confirm {
		slog.Info("removal plan prepared",
			"actions", len(plan.Actions), "blockers", len(plan.Blockers))
		return &Response{Phase: "remove-piri", DryRun: true, RemovePiriPlan: plan}, nil
	}

	slog.Info("performing the removal writes", "actions", plan.Actions)
	result, err := onboard.ApplyRemoval(ctx, removeDeps, removeReq, plan)
	if err != nil {
		return nil, err
	}

	slog.Info("Piri removed", "region", req.Region, "piri", req.PiriDID, "performed", result.Performed)
	return &Response{Phase: "remove-piri", RemovePiriResult: result}, nil
}

func validateRemovePiriRequest(req Request) error {
	var missing []string
	if req.Region == "" {
		missing = append(missing, "region")
	}
	if req.PiriDID == "" {
		missing = append(missing, "piri_did")
	}
	if len(missing) > 0 {
		return fmt.Errorf("the remove-piri phase needs %v", missing)
	}

	if _, err := piriParameterName(req.PiriDID); err != nil {
		return fmt.Errorf("piri_did: %w", err)
	}
	return nil
}
