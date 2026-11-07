# The proofs of LAWS.bend.
import Base
import ./blink/frame.bend as F
import ./LAWS.bend as Laws

# Induction on a: each byte of a steps the framer once on either side.
def Laws.feed_split(a, b, rx):
  match a:
    case Nil{}:
      {==}
    case +h <> t:
      Laws.feed_split(t, b, F.step(rx, h))

def Laws.utf8_sample():
  {==}

def Laws.query_bytes():
  {==}

def Laws.ready_split():
  {==}

def Laws.error_fields():
  {==}

def Laws.typed_row():
  {==}

def Laws.scram_signature_checked():
  {==}

def Laws.scram_signature_accepted():
  {==}

def Laws.scram_not_skipped():
  {==}

def Laws.failed_login_stays_failed():
  {==}

def Laws.extended_bytes():
  {==}

def Laws.batches_continue():
  {==}

def Laws.cancel_stops_batches():
  {==}
