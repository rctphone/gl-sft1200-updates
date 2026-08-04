#!/bin/bash
#set -x
# Function to extract the control file from an IPK package and append it to the output file
extract_control_from_ipk() {
    ipk_file=$1
    output_file=$2
    category=$3
    filename=$(basename "$ipk_file")

    echo "Processing IPK file: $ipk_file"

    # Decompress the IPK file (gzip compressed)
    gzip -d -c "$ipk_file" > temp.tar
    if [ $? -ne 0 ]; then
        echo "Error: Failed to decompress $ipk_file"
        exit 1
    fi

    # Extract control.tar.gz from the tar archive
    tar --strip-components=1 -xf temp.tar ./control.tar.gz
    if [ $? -ne 0 ]; then
        echo "Error: Failed to extract control.tar.gz from $ipk_file"
        rm temp.tar
        exit 1
    fi

    # Extract control file from control.tar.gz
    control_file=$(mktemp)
    tar -xzOf control.tar.gz ./control > "$control_file"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to extract control file from control.tar.gz"
        rm temp.tar control.tar.gz
        exit 1
    fi

    # Add the appropriate tag to the Description field based on the category
    if [ "$category" == "curated" ]; then
        tag="curated"
    elif [ "$category" == "supported" ]; then
        tag="supported"
    else
        tag=""
    fi

    if [ -n "$tag" ]; then
        sed -i "s/^Description:/Description: $tag /" "$control_file"
    fi

    # Append the control file contents to the output file.
    #
    # A paragraph break inside Description must be written as " ." -- a line
    # holding only whitespace terminates the record for opkg, which then never
    # reaches Filename and reports "does not have a valid filename field".
    # Three packages shipped that way, including gl-sft1200-amneziawg-compat,
    # which was therefore uninstallable from this feed for as long as it has
    # been in it, with nothing to say so: `opkg list` and `list-upgradable`
    # only need Package and Version, so the package looked perfectly present
    # right up until someone tried to install it.
    sed 's/^[[:space:]]*$/ ./' "$control_file" >> "$output_file"

    # Add the Filename field to the output file
    echo "Filename: $filename" >> "$output_file"

    # Size and SHA256sum are what opkg checks a download against.  Without
    # them it installs whatever it received -- a truncated transfer or a
    # substituted file goes in silently.  They were present in the published
    # index but this script never wrote them, so every regeneration quietly
    # dropped both fields from every entry.
    echo "Size: $(wc -c < "$ipk_file" | tr -d ' ')" >> "$output_file"
    echo "SHA256sum: $(sha256sum "$ipk_file" | cut -d' ' -f1)" >> "$output_file"

    # Clean up temporary files
    rm temp.tar control.tar.gz "$control_file"
    echo "" >> "$output_file" # Add an empty line between entries
}

# Function to generate the Packages file by processing each IPK package in the directory
generate_packages() {
    ipk_dir=$1
    output_file=$2
    category=$3

    > "$output_file" # Empty the file before appending new data

    echo "Looking for IPK files in directory: $ipk_dir"

    # Find all IPK files in the directory and process each one
    find "$ipk_dir" -maxdepth 1 -type f -name '*.ipk' | while read -r ipk; do
        extract_control_from_ipk "$ipk" "$output_file" "$category"
    done

    echo "Packages file generated at $output_file"
}

# Function to generate Packages.manifest: one record per ipk, naming the
# package and every file it installs.
generate_manifest() {
    ipk_dir=$1
    output_file=$2

    > "$output_file"

    find "$ipk_dir" -maxdepth 1 -type f -name '*.ipk' | while read -r ipk; do
        name=$(basename "$ipk" .ipk)
        printf 'Package: %s\n' "$name" >> "$output_file"
        gzip -d -c "$ipk" > mtemp.tar 2>/dev/null || { echo "Error: cannot read $ipk"; rm -f mtemp.tar; exit 1; }
        tar --strip-components=1 -xf mtemp.tar ./data.tar.gz 2>/dev/null || {
            echo "Error: no data.tar.gz in $ipk"; rm -f mtemp.tar; exit 1; }
        # Files only -- directories are not installed content, and the
        # leading "." of the ipk's internal paths is not part of the
        # installed path.
        tar -tzf data.tar.gz 2>/dev/null | sed -n 's,^\./,/,p' | grep -v '/$' >> "$output_file"
        printf '\n' >> "$output_file"
        rm -f mtemp.tar data.tar.gz
    done

    echo "Manifest generated at $output_file"
}

# Main script execution
category="Base system"
ipk_dir="."
packages_file="${ipk_dir}/Packages"

generate_packages "$ipk_dir" "$packages_file" "$category"

# Verify that the Packages file is not empty
if [ ! -s "$packages_file" ]; then
    echo "Error: Packages file is empty or does not exist."
    exit 1
fi

generate_manifest "$ipk_dir" "${ipk_dir}/Packages.manifest"

# opkg reads Packages.gz, not Packages.  Nothing here used to write it: the
# compressed copy and the manifest sat in the repository and were never
# regenerated, so they drifted from the index for as long as anyone had been
# editing it.  That shipped once -- Packages honestly listed the twenty
# packages the feed holds while Packages.gz still advertised twenty-four,
# five of whose files had been withdrawn.  Every check at the time was run
# against Packages, which was correct; nothing compared it with the file
# opkg actually downloads.
gzip -9 -c "$packages_file" > "${ipk_dir}/Packages.gz" || {
    echo "Error: failed to write Packages.gz"; exit 1; }

# --- consistency, checked across the three surfaces, not within each -------
#
# Each of these has failed in this feed at least once.  They are cheap, and a
# feed that fails to publish is recoverable in a way that a feed advertising
# packages it does not have is not: opkg reports a download failure to the
# user and leaves the router mid-upgrade.
fail=0

# 1. The compressed copy must be this index, not an older one.
#
#    Be clear about what this is worth: the line above writes Packages.gz
#    from Packages, so within one run this comparison is a tautology and
#    cannot fail on drift.  Drift was the bug, and generating the file is
#    what fixed it -- not this check, which only catches a failed gzip or a
#    full disk.  It is kept because the cost is a millisecond and the
#    failure it does catch is silent.  Do not read a passing line here as
#    evidence that the published .gz matches the published index: for that,
#    compare them after checkout, not after generation.
if ! gzip -d -c "${ipk_dir}/Packages.gz" | cmp -s - "$packages_file"; then
    echo "FAIL: Packages.gz does not decompress to Packages"
    fail=1
fi

# 2. Every file the index advertises must exist, or opkg 404s mid-install.
while read -r fn; do
    [ -f "${ipk_dir}/${fn}" ] || { echo "FAIL: Packages names $fn, which is not in the feed"; fail=1; }
done <<EOF
$(awk '/^Filename:/{print $2}' "$packages_file")
EOF

# 3. Every ipk present must be advertised, or it is dead weight nobody can
#    install and a later reader will wonder which of the two is stale.
for f in "${ipk_dir}"/*.ipk; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    grep -qx "Filename: $b" "$packages_file" || {
        echo "FAIL: $b is in the feed but not in Packages"; fail=1; }
done

# 4. The manifest must describe the same set.
idx_n=$(grep -c '^Package:' "$packages_file")
man_n=$(grep -c '^Package:' "${ipk_dir}/Packages.manifest")
if [ "$idx_n" != "$man_n" ]; then
    echo "FAIL: Packages has $idx_n records, Packages.manifest has $man_n"
    fail=1
fi

# 5. Size and SHA256sum are what opkg validates a download against; a record
#    missing them installs whatever arrived.  A whitespace-only line inside a
#    Description terminates the record, after which opkg never reaches
#    Filename and calls the package invalid -- it stays visible in `opkg
#    list`, so nothing looks wrong until someone tries to install it.
for k in Filename Size SHA256sum; do
    n=$(grep -c "^$k:" "$packages_file")
    [ "$n" = "$idx_n" ] || { echo "FAIL: $idx_n records but $n $k lines"; fail=1; }
done
if grep -qE '^[[:space:]]+$' "$packages_file"; then
    echo "FAIL: a whitespace-only line inside a record truncates it for opkg"
    fail=1
fi

if [ "$fail" != "0" ]; then
    echo "Index is inconsistent; not safe to publish."
    exit 1
fi

echo "Index OK: $idx_n packages, Packages.gz matches, every file present."
