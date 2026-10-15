# Dynamic MacNotch MediaRemote 어댑터 실행기: perl -- run.pl <dylib 경로>
use strict;
use DynaLoader;
my $lib = shift or die "usage: run.pl <dylib>";
my $handle = DynaLoader::dl_load_file($lib, 0) or die "load failed: " . DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($handle, "adapter_run") or die "symbol missing";
DynaLoader::dl_install_xsub("main::adapter_run", $sym);
adapter_run();
