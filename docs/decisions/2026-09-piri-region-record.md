# Piri nodes are recorded by region

The onboard request is the only point where central receives both a region and
its Piri DID. On a confirmed onboard, central records that DID in SSM under the
region's appliance prefix. sprue's provider row has no region and hilt's row has
no Piri DID, so neither can recover the association.

The list is for a future region-retirement path that must find every Piri
provider to deregister. It is an interim record, not the node registry.
[FIL-1130](https://linear.app/filecoin-foundation/issue/FIL-1130) tracks the
proper per-region Piri registry.
