# ROM Test Data

Put test ROMs under:

```text
.github/data/roms/<system>/<files>
```

Use `.github/scripts/import-batocera-test-data.sh` to populate this folder. The importer also populates `.github/data/bios` from `/userdata/bios` when a Batocera SSH password is provided. The local Drone containers copy a different subset of these files into their own Batocera-like `/userdata/roms` folders at startup and copy BIOS files into `/userdata/bios`.
