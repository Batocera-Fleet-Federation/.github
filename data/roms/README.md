# ROM Test Data

Put test ROMs under:

```text
.github/data/roms/<system>/<files>
```

Use `.github/scripts/import-roms-remotely.sh` to populate this folder. The local Drone containers copy a different subset of these files into their own Batocera-like `/userdata/roms` folders at startup.
