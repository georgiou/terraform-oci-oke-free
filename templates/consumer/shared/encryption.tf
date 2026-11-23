# Symlinked into both roots.
#
# OpenTofu client-side encryption: state and plan files are AES-GCM encrypted
# before they ever reach Object Storage. The bucket only ever sees ciphertext,
# so leaked Customer Secret Keys don't leak your cluster secrets.
#
# OpenTofu has no OCI KMS key provider, so PBKDF2 over a passphrase is used.
# Keep the passphrase in a password manager; losing it means losing state.
terraform {
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }

    # Lets 10-network / 20-oke read the encrypted state of earlier stacks.
    remote_state_data_sources {
      default {
        method = method.aes_gcm.main
      }
    }
  }
}
