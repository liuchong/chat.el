package sample

import "testing"

func TestDivide(t *testing.T) {
	if Divide(5, 2) != 3 {
		t.Fatal("integer division must round up")
	}
}

func TestLabel(t *testing.T) {
	if Label("alpha") != "entry:alpha" {
		t.Fatal("unexpected label")
	}
}

func TestNormalize(t *testing.T) {
	if NormalizeName("  Alpha   BETA ") != "alpha beta" {
		t.Fatal("unexpected normalized name")
	}
}

func TestActive(t *testing.T) {
	if !Active(Status{State: "active"}) || Active(Status{State: "paused"}) {
		t.Fatal("unexpected activity state")
	}
}
