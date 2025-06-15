using Pkg
Pkg.activate(@__DIR__)
using Dates
using CSV
using DataFrames
using Downloads: download
using HTTP

const SITE_DIR = joinpath(@__DIR__, "..")
const SITE_INDEX_TEMPLATE = joinpath(@__DIR__, "index.template.html")
const MAP_KML_TEMPLATE = joinpath(@__DIR__, "map.template.kml")

function get_table_html(df)
    str = """
          <table>
                    <thead>
                        <tr>
                        {{ TABLE_HEAD }}
                        </tr>
                    </thead>
                    <tbody>
                    {{ TABLE_ROWS }}
                    </tbody>
                </table>
                """

    # Table head...
    rows_str = join(["<td>" * v * "</td>\n" for v in names(df)], "")
    str = replace(str, "{{ TABLE_HEAD }}" => rows_str)

    # Table body...
    rows_str = map(eachrow(df)) do entry
        row_str = ["<td>" * v * "</td>\n" for v in values(entry)]
        replace!(row_str, missing => "<td></td>\n")
        return "<tr>\n" * join(row_str, "") * "</tr>\n"
    end
    return str = replace(str, "{{ TABLE_ROWS }}" => join(rows_str, "\n"))
end

function generate_index!(entries_df)
    index_path = joinpath(SITE_DIR, "index.html")
    index_str = read(SITE_INDEX_TEMPLATE, String)

    map_path = joinpath(SITE_DIR, "map.kml")
    map_str = read(MAP_KML_TEMPLATE, String)

    data = select(entries_df,
                  :Classification,
                  Symbol("Name of place") => :Place,
                  Symbol("Google maps link") => ByRow(str -> "<a href=\"$str\">[link]</a>") => :Link,
                  Symbol("Google maps link") => ByRow(identity) => :raw_link,
                  :Comments => ByRow(str -> ismissing(str) ? "" : str) => :Details,
                  Symbol("Timestamp") => ByRow(str -> Dates.format(Date(first(split(str, " ")), dateformat"m/d/yyyy"), dateformat"uu yyyy")) => Symbol("Last checked"))

    for gdf in groupby(data, :Classification)
        title = first(gdf.Classification)
        template_key = replace(uppercase(title), " " => "_")

        # Process for site
        data_html_str = get_table_html(select(gdf, Not(:Classification, :raw_link)))
        index_str = replace(index_str, "{{ $template_key }}" => data_html_str)
        index_str = replace(index_str, "{{ $(template_key)_COUNT }}" => nrow(gdf))

        # Process for map
        data_kml_str = get_map_kml(select(gdf, Not(:Classification)), template_key)
        map_str = replace(map_str, "{{ $template_key }}" => data_kml_str)
    end
    write(index_path, index_str)
    write(map_path, map_str)

    try
        run(`prettier $(index_path) --write --print-width 360`)
        run(`prettier $(map_path) --write --parser=html`)
    catch
        @warn "Prettier not installed OR current html errors"
    end
    return nothing
end

function get_map_kml(df, title)
    data_str = map(eachrow(df)) do entry
        # TODO - could use name from url instead of form entry...

        _trunc_number = n -> begin
            x = split(n, ".")
            return first(x) * "." * last(x)[1:6] 
        end

        _coordinates = url -> begin 
            expanded_url = read(pipeline(`curl -s -I "$url"`, `awk '/location:/{print $2}'`), String)
            if contains(expanded_url, "!8m2!")
                str = last(split(expanded_url, "!8m2!"))
                strs = split(str, "!")
                lat = strs[1][3:end]
                lon = strs[2][3:end]
                return "$lon,$lat"
            end
            @warn "UH OH, to get coordinates make sure that link is of form https://maps.app.goo.gl/FOO" url expanded_url
            return 0,0
        end

        _format = raw -> begin
            return "<![CDATA[$raw]]>"
        end

        style_url = if title == "WE_GO_HERE"
            "#icon-1502-0F9D58"
        elseif title == "WE_GO_HERE_CAUTIOUSLY"
            "#icon-1541-FBC02D"
        elseif title == "WE_WOULD_LIKE_TO_GO_HERE"
            "#icon-1524-F57C00"
        elseif title == "WE_COULD_NEVER_GO_HERE"
            "#icon-1556-C2185B"
        else
            "#icon-1899-0288D1"
        end

        data_str = """  
                <name>$(_format(entry.Place))</name>
                <description>$(_format(entry.Details)) $(entry.raw_link)</description>
                <styleUrl>$style_url</styleUrl>
                <Point>
                  <coordinates>$(_coordinates(entry.raw_link))</coordinates>
                </Point>
        """
        return "      <Placemark>" * data_str * "      </Placemark>"
    end
    return join(data_str, "\n")
end

function download_data!(data_path, id)
    url = "https://docs.google.com/spreadsheets/d/$(id)/export?format=csv"
    io = IOBuffer()
    download(url, io)
    str = String(take!(io))
    write(data_path, str)
    return nothing
end

# Thanks, https://discourse.julialang.org/t/how-to-best-store-and-access-credentials-in-julia/54997/12 !
function load_secrets(filename="secrets.env")
    isfile(filename) || return
    i = 0
    for line in eachline(filename)
        var, val = strip.(split(line, "="))
        ENV[var] = val
        i += 1
    end
    return println("\t$i secret(s) loaded")
end

# Run from commandline? 
if abspath(PROGRAM_FILE) == @__FILE__
    data_path = joinpath(SITE_DIR, "data.csv")
    kml_path = joinpath(SITE_DIR, "map.kml")
    if "--download" in ARGS
        @info "...downloading data..."
        load_secrets()
        id = get(ENV, "GOOGLE_SHEET_ID", missing)
        download_data!(data_path, id)
    else
        @info "Using pre-downloaded data..."
    end
    entry_list = CSV.read(data_path, DataFrame)
    println("\t$(nrow(entry_list)) entries found")

    @info "...generating index.html and map kml..."
    generate_index!(entry_list)

    @warn "Manual kml upload required!" kml_path upload_path = "https://www.google.com/maps/d/u/0/edit?mid=1ByVtx0dsYJ8E_suvTlCRM363DHYZ6Io&ll=42.38098637730792%2C-71.09826765&z=16"

    @info "Complete!"
    return nothing
end
