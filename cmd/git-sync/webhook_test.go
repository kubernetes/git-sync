package main

import (
	"fmt"
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

		<-whd.Events()

		hash := whd.Hash()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})

	t.Run("last update wins when channel buffer is full", func(t *testing.T) {
		whd := NewWebhookData()

		for i := 0; i < 10; i++ {
			h := fmt.Sprintf("111111111111111111111111111111111111111%d", i)
			whd.UpdateAndTrigger(h)
		}
		whd.UpdateAndTrigger(hash2)

		<-whd.Events()

		hash := whd.Hash()
		if hash2 != hash {
			t.Fatalf("expected hash %s but got %s", hash2, hash)
		}
	})

	t.Run("same hash value", func(t *testing.T) {
		whd := NewWebhookData()
		events := whd.Events()

		whd.UpdateAndTrigger(hash1)
		<-events

		hash := whd.Hash()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}

		whd.UpdateAndTrigger(hash1)
		<-events

		hash = whd.Hash()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})
}
