# Validation provenance

`original/` preserves the logs and environment record supplied with the original
source archive. Those logs report a Linux check of the earlier source, not the
current pull-request revision. The package's five runtime R files are unchanged
from that archive; review additions are documentation and context-contract tests.

Current local environment: no R or Rscript executable is installed. Runtime tests
and R CMD check were not rerun locally. The pull request includes a GitHub Actions
workflow for Linux, Windows, and macOS; consult the actual run status before
claiming a pass for this revision. Static comparison of recovered runtime files
and Git blob hashes is independent of executing the R test suite.

No multi-host NFS/SMB, cloud-backend, capacity, retention, or throughput validation
has been performed for this pull request.
