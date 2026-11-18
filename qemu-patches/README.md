# QEMU patches for Hybrid Hypervisor

**These patches are not covered by the repository's LICENSE (Apache-2.0).** They modify QEMU and carry code
from the QEMU integration in Virtual Intel Mac, so they are under QEMU's license, GPL-2.0-or-later, as their
file headers say.

They apply to upstream QEMU `master` at the commit pinned as `QEMU_COMMIT` in [`../build.sh`](../build.sh), which
downloads that commit and applies them with `git am`.
The `From:` header of the patches is a placeholder (`nobody <nobody@localhost>`); see below for the actual origin and
authorship.

| Patch | What it does |
|---|---|
| 0001 | Adds the hand-off interface (`TcgHandoffOps`, `EXCP_HANDOFF`) and guarded translation blocks. |
| 0002 | Adds `-accel tcg,hybrid=on`, which selects an engine built into QEMU. |
| 0003 | Exposes `cpu_exclusive_pending()` and `cpu_get_ticks_offset()` to an engine. |
| 0004 | Tells the engine about RAM writes made outside it, and adds a dirty-range helper. |
| 0005 | Hands vCPUs to the engine at translation-block boundaries. |
| 0006 | Adds `target/i386/tcg/system/hvdbt.c`, the glue to Hybrid Hypervisor, and the `-Dhvdbt_engine` build option. |

With the option off, or without `hybrid=on`, TCG behaves as upstream QEMU.

## Origin and credit

Hybrid Hypervisor was invented by **Sam Henri Gold** (developer of Light Touch, https://github.com/samhenrigold).
These patches port its QEMU integration from **Virtual Intel Mac by nfzerox**
(https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon), at commit
[`0c29f1f0`](https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon/commit/0c29f1f0fcaff59fdb6721f7ffa8b4a8c8decb65),
from the files under `Source/vendor/qemu/`. Each patch names the files it was ported from and carries
`Originally-by:` trailers. The files taken over whole link to their originals in their headers.

The port rebased the integration onto upstream QEMU master, dropped unrelated changes from that fork, replaced the
`LC_HVDBT` environment switch with the `hybrid` accelerator property, and added two helpers the fork had.
