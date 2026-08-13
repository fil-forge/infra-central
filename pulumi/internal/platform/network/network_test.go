package network

import "testing"

// TestSubnetLayout pins the addresses a stage actually gets. The arithmetic
// behind them is go-cidr's and is not this project's to test; what matters here is
// that the layout has not moved, because a changed range replaces every subnet and
// with them the database and every task.
func TestSubnetLayout(t *testing.T) {
	layout, err := subnetLayout("10.20.0.0/16", 2)
	if err != nil {
		t.Fatalf("subnetLayout: %v", err)
	}

	// Public first, private offset by the number of zones, so the two ranges
	// cannot overlap.
	wantPublic := []string{"10.20.0.0/20", "10.20.16.0/20"}
	wantPrivate := []string{"10.20.32.0/20", "10.20.48.0/20"}

	assertEqual(t, "public", layout.public, wantPublic)
	assertEqual(t, "private", layout.private, wantPrivate)
}

// TestSubnetLayoutRejectsAnOverfullPrefix covers the one way a stage can ask for
// something the CIDR cannot hold: four new bits leave room for 16 ranges, so nine
// zones needs eighteen and fails before anything is created.
func TestSubnetLayoutRejectsAnOverfullPrefix(t *testing.T) {
	if _, err := subnetLayout("10.20.0.0/16", 9); err == nil {
		t.Error("expected nine zones to exhaust a /16 split into /20s, got no error")
	}

	if _, err := subnetLayout("not-a-prefix", 2); err == nil {
		t.Error("expected an unparseable cidr to fail")
	}
}

func assertEqual(t *testing.T, what string, got, want []string) {
	t.Helper()

	if len(got) != len(want) {
		t.Fatalf("%s: got %d ranges, want %d: %v", what, len(got), len(want), got)
	}

	for index := range want {
		if got[index] != want[index] {
			t.Errorf("%s[%d] = %s, want %s", what, index, got[index], want[index])
		}
	}
}
