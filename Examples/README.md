# The examples moved — this directory is intentionally almost empty

**All bitHuman examples now live in
[gitlab.com/bithuman/sdk/bithuman-examples](https://gitlab.com/bithuman/sdk/bithuman-examples).**

This copy was a byte-identical duplicate of that repository, kept "so existing links keep
working". It also kept its defects working: a 20 fps engine paced on a 25 fps grid sat here
after the canonical copy was fixed, because an edit here is not carried over. Two copies of
a customer-facing example, one of them marked *do not edit*, is a trap for whoever edits
next — so the duplicate is gone and this file is what remains.

**If you followed a link or an older doc that said `git clone … && cd Examples/…`**, the
clone succeeded and the directory is not here. That is this change, not a broken checkout.
Clone the examples repository instead:

```bash
git clone https://gitlab.com/bithuman/sdk/bithuman-examples.git
cd bithuman-examples
```

## Where each thing went

Most paths are unchanged under the new root. One moved, so check it if a path does not
resolve:

| was, here | is, in `bithuman-examples` |
|---|---|
| `Examples/swift/…` | `swift/…` (all eleven packages, same names) |
| `Examples/android/…` | `android/…` |
| `Examples/integrations/…` | `integrations/…` |
| `Examples/python/…` | `python/…` |
| `Examples/rest-api/…` | `rest-api/…` |
| **`Examples/quickstart/…`** | **`python/quickstart/…`** |

Nothing in this repository builds from or resolves into `Examples/` — the Swift package's
binary targets are fetched from release assets by URL and checksum, and no workflow reads
this path. Documentation links were repointed before the directory was removed.
