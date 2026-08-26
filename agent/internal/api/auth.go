package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
)

type Authenticator interface {
	Authenticate(context.Context, string) (bool, error)
}

type staticAuthenticator struct {
	digest [sha256.Size]byte
}

func NewStaticAuthenticator(token string) Authenticator {
	return staticAuthenticator{digest: sha256.Sum256([]byte(token))}
}

func (authenticator staticAuthenticator) Authenticate(_ context.Context, token string) (bool, error) {
	provided := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(authenticator.digest[:], provided[:]) == 1, nil
}

type anyAuthenticator struct {
	authenticators []Authenticator
}

func NewAnyAuthenticator(authenticators ...Authenticator) Authenticator {
	return anyAuthenticator{authenticators: authenticators}
}

func (authenticator anyAuthenticator) Authenticate(ctx context.Context, token string) (bool, error) {
	for _, candidate := range authenticator.authenticators {
		authenticated, err := candidate.Authenticate(ctx, token)
		if err != nil {
			return false, err
		}
		if authenticated {
			return true, nil
		}
	}
	return false, nil
}
