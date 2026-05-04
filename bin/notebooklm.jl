#!/usr/bin/env julia

using Printf

const TARGET_DIRS = ["skill", "src"]
const OUTPUT_FILE = joinpath(pwd(), "context.txt")

function collect_files(root::String)
    files = String[]
    for (dirpath, _, filenames) in walkdir(root)
        for filename in filenames
            push!(files, joinpath(dirpath, filename))
        end
    end
    sort!(files)
    return files
end

function read_text_file(path::String)
    try
        return read(path, String)
    catch err
        @warn "Skipping unreadable/non-UTF8 file" path error=err
        return nothing
    end
end

function relative_to_cwd(path::String)
    rel = relpath(path, pwd())
    return replace(rel, "\\" => "/")
end

function main()
    all_files = String[]

    for dir in TARGET_DIRS
        dir_path = joinpath(pwd(), dir)
        if !isdir(dir_path)
            @warn "Directory not found, skipping" dir_path
            continue
        end
        append!(all_files, collect_files(dir_path))
    end

    if isempty(all_files)
        @warn "No files found in target directories" dirs=TARGET_DIRS
        open(OUTPUT_FILE, "w") do io
            write(io, "")
        end
        @info "Created empty output file" output=OUTPUT_FILE
        return
    end

    open(OUTPUT_FILE, "w") do io
        for file_path in all_files
            content = read_text_file(file_path)
            content === nothing && continue

            rel_path = relative_to_cwd(file_path)
            write(io, "<document path=\"$(rel_path)\">\n\n")
            write(io, strip(content))
            write(io, "\n\n</document>\n\n")
            @printf(" + added %s\n", rel_path)
        end
    end

    @info "Saved merged context" output=OUTPUT_FILE
end

main()
