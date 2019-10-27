package main

import (
	"testing"
)

const (
	hash1 = "1111111111111111111111111111111111111111"
	hash2 = "2222222222222222222222222222222222222222"
)

func TestWebhookData(t *testing.T) {
	t.Run("webhhook consumes first hash value", func(t *testing.T) {
		whd := NewWebhookData()

		whd.UpdateAndTrigger(hash1)
		whd.WaitForChange()

		hash := whd.Hash()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})

	t.Run("second update wins", func(t *testing.T) {
		whd := NewWebhookData()

		whd.UpdateAndTrigger(hash1)
		whd.UpdateAndTrigger(hash2)
		whd.WaitForChange()

		hash := whd.Hash()
		if hash2 != hash {
			t.Fatalf("expected hash %s but got %s", hash2, hash)
		}
	})

	t.Run("same hash value does not lead to an update", func(t *testing.T) {
		whd := NewWebhookData()

		whd.UpdateAndTrigger(hash1)
		whd.WaitForChange()
		hash := whd.Hash()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}

		whd.UpdateAndTrigger(hash1)
		changed := whd.Wait()

		if changed {
			t.Fatalf("no change expected")
		}

		hash = whd.Hash()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})
}
