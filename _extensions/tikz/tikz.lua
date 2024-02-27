-- Enum for TikzFormat
local TikzFormat = {
  svg = 'svg',
  pdf = 'pdf'
}

-- Enum for Embed mode
local EmbedMode = {
  inline = "inline",
  link = "link",
  raw = "raw"
}

-- Helper function for file existence
local function file_exists(name)
  local f = io.open(name, 'r')
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end
-- Helper function for debugging
local function serialize(obj, indentLevel)
  indentLevel = indentLevel or 0
  local indent = string.rep("  ", indentLevel)
  local indentNext = string.rep("  ", indentLevel + 1)

  if type(obj) == "table" then
    local parts = {}
    table.insert(parts, "{\n")
    for k, v in pairs(obj) do
      local keyStr = (type(k) == "string" and string.format("%q", k) or tostring(k))
      table.insert(parts, indentNext .. "[" .. keyStr .. "] = " .. serialize(v, indentLevel + 1) .. ",\n")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts)
  else
    return (type(obj) == "string" and string.format("%q", obj) or tostring(obj))
  end
end

local function debugPrint(options, obj)
  if options.debug then
    print(serialize(obj))
  end
end

local function debugLog(options, obj)
  if options.debug then
    quarto.log.output(serialize(obj))
  end
end

-- Helper function to copy a table
function copyTable(obj, seen)
  if type(obj) ~= 'table' then return obj end
  if seen and seen[obj] then return seen[obj] end

  local s = seen or {}
  local res = {}
  s[obj] = res
  for k, v in pairs(obj) do res[copyTable(k, s)] = copyTable(v, s) end
  return setmetatable(res, getmetatable(obj))
end

-- Counter for the diagram files
local counter = 0

local function createTexFile(tikzCode, tmpdir, outputFile, scale, libraries)
  scale = scale or 1          -- Default scale is 1 if not provided
  local defaultLibraries = { "arrows", "fit", "shapes" }
  libraries = libraries or "" -- Default libraries is an empty string if not provided

  -- Split the libraries string into a table
  local providedLibraries = {}
  for lib in string.gmatch(libraries, '([^,]+)') do
    table.insert(providedLibraries, lib)
  end

  -- Append the provided libraries to the default set
  for _, lib in ipairs(providedLibraries) do
    table.insert(defaultLibraries, lib)
  end

  local template = [[
\documentclass[tikz]{standalone}
\usepackage{amsmath}
\usetikzlibrary{%s}
\begin{document}
\begin{tikzpicture}[scale=%s, transform shape]
%s
\end{tikzpicture}
\end{document}
  ]]

  -- Create a comma-separated string of library names
  local libraryNames = table.concat(defaultLibraries, ",")

  local texCode = string.format(template, libraryNames, scale, tikzCode)
  local texFile = pandoc.path.join({ tmpdir, outputFile .. ".tex" })
  local file = io.open(texFile, "w")
  debugPrint(texCode)
  print(texCode)
  file:write(texCode)
  file:close()

  return texFile
end

local function tikzToSvg(tikzCode, tmpdir, outputFile, scale, libraries)
  local texFile = createTexFile(tikzCode, tmpdir, outputFile, scale, libraries)
  local dviFile = pandoc.path.join({ tmpdir, outputFile .. ".dvi" })
  local svgFile = pandoc.path.join({ tmpdir, outputFile .. ".svg" })

  local _, _, latexExitCode = os.execute("latex -interaction=nonstopmode -output-directory=" .. tmpdir .. " " .. texFile)
  if latexExitCode ~= 0 then
    error("latex failed with exit code " .. latexExitCode)
  end

  local _, _, dvisvgmExitCode = os.execute("dvisvgm --font-format=woff " .. dviFile .. " -n -o " .. svgFile)
  if dvisvgmExitCode ~= 0 then
    error("dvisvgm failed with exit code " .. dvisvgmExitCode)
  end

  os.remove(texFile)
  os.remove(dviFile)
  return svgFile
end

local function tikzToPdf(tikzCode, tmpdir, outputFile, scale, libraries)
  local texFile = createTexFile(tikzCode, tmpdir, outputFile, scale, libraries)
  local pdfFile = pandoc.path.join({ tmpdir, outputFile .. ".pdf" })

  local _, _, latexExitCode = os.execute("latex -pdf -output-directory=" .. tmpdir .. " " .. texFile)
  if latexExitCode ~= 0 then
    error("latex failed with exit code " .. latexExitCode)
  end

  os.remove(texFile)
  return pdfFile
end

-- Initializes and processes the options for the TikZ code block
local function processOptions(cb, globalOptions)
  local options = copyTable(globalOptions)

  -- Process codeblock attributes
  for k, v in pairs(cb.attributes) do
    options[k] = v
  end

  -- Transform options
  if options.format ~= nil and type(options.format) == "string" then
    assert(TikzFormat[options.format] ~= nil,
      "Invalid format: " .. options.format .. ". Options are: " .. serialize(TikzFormat))
    options.format = TikzFormat[options.format]
  end
  if options.embed_mode ~= nil and type(options.embed_mode) == "string" then
    assert(EmbedMode[options.embed_mode] ~= nil,
      "Invalid embed_mode: " .. options.embed_mode .. ". Options are: " .. serialize(EmbedMode))
    options.embed_mode = EmbedMode[options.embed_mode]
  end

  -- Set default values
  options.filename = (options.filename or "tikz-output") .. "-" .. counter
  if options.format == TikzFormat.svg and quarto.doc.is_format("latex") then
    options.format = TikzFormat.pdf
  end
  if not quarto.doc.is_format("html") or options.format == TikzFormat.pdf then
    options.embed_mode = EmbedMode.link
  end
  if options.folder == nil and options.embed_mode == EmbedMode.link then
    options.folder = "./images"
  end

  -- Set cache path
  options.cache = options.cache or nil

  -- Set debug option
  options.debug = options.debug or false

  return options
end

-- Renders the TikZ code block, returning the result path or data depending on the embed mode
local function renderTikz(cb, options, tmpdir)
  local outputPath, tempOutputPath
  if options.folder ~= nil then
    os.execute("mkdir -p " .. options.folder)
    tempOutputPath = pandoc.path.join({ tmpdir, options.filename .. "." .. options.format })
    outputPath = options.folder .. "/" .. options.filename .. "." .. options.format
  else
    tempOutputPath = pandoc.path.join({ tmpdir, options.filename .. "." .. options.format })
    outputPath = tempOutputPath
  end

  -- Check if the result is already cached
  local cachePath
  if options.cache ~= nil then
    cachePath = pandoc.path.join({ options.cache, pandoc.sha1(cb.text) .. "." .. options.format })
    if file_exists(cachePath) then
      if options.embed_mode == EmbedMode.link then
        os.execute("cp " .. cachePath .. " " .. outputPath)
        return outputPath
      else
        local file = io.open(cachePath, "rb")
        local data = file and file:read('*all')
        if file then file:close() end
        if options.embed_mode == EmbedMode.inline then
          local mimeType = (options.format == "svg" and "image/svg+xml") or "application/pdf"
          return "data:" .. mimeType .. ";base64," .. quarto.base64.encode(data)
        else
          return data
        end
      end
    end
  end

  if quarto.doc.isFormat("html") then
    tikzToSvg(cb.text, tmpdir, options.filename, options.scale, options.libraries)
  elseif quarto.doc.isFormat("pdf") then
    tikzToPdf(cb.text, tmpdir, options.filename, options.scale, options.libraries)
  else
    print("Error: Unsupported format")
    return nil
  end

  if tempOutputPath ~= outputPath then
    os.rename(tempOutputPath, outputPath)
  end

  if options.embed_mode == EmbedMode.link then
    -- Save the result to the cache
    if options.cache ~= nil then
      os.execute("mkdir -p " .. pandoc.path.directory(cachePath))
      os.execute("cp " .. outputPath .. " " .. cachePath)
    end
    return outputPath
  else
    local file = io.open(outputPath, "rb")
    local data = file and file:read('*all')
    if file then file:close() end
    os.remove(outputPath)

    -- Save the result to the cache
    if options.cache ~= nil then
      os.execute("mkdir -p " .. pandoc.path.directory(cachePath))
      local cacheFile = io.open(cachePath, "wb")
      cacheFile:write(data)
      cacheFile:close()
    end

    if options.embed_mode == EmbedMode.raw then
      return data
    elseif options.embed_mode == EmbedMode.inline then
      local mimeType = (options.format == "svg" and "image/svg+xml") or "application/pdf"
      return "data:" .. mimeType .. ";base64," .. quarto.base64.encode(data)
    else
      debugLog("Error: Unsupported format")
      return nil
    end
  end
end

-- Main function to create the TikZ filter
local function tikz_walker(globalOptions)
  return {
    CodeBlock = function(cb)
      if not cb.classes:includes('tikz') or cb.text == nil then
        return nil
      end

      counter = counter + 1
      local options = processOptions(cb, globalOptions)

      local result = pandoc.system.with_temporary_directory('tikz-convert', function(tmpdir)
        return renderTikz(cb, options, tmpdir)
      end)

      local caption = options.caption ~= '' and { pandoc.Str(options.caption) } or nil
      local figure = pandoc.Figure({ pandoc.Image({}, result) }, caption)
      if options.width ~= nil then
        figure.content[1].attributes.width = options.width
      end
      if options.height ~= nil then
        figure.content[1].attributes.height = options.height
      end

      return figure
    end
  }
end

function Pandoc(doc)
  local options = {
    format = TikzFormat.svg,
    folder = nil,
    filename = pandoc.utils.stringify(doc.meta.slug or "tikz-output"),
    caption = '',
    width = nil,
    height = nil,
    embed_mode = EmbedMode.inline,
    cache = nil
  }

  -- Process global attributes
  local globalOptions = doc.meta["tikz"]
  if type(globalOptions) == "table" then
    for k, v in pairs(globalOptions) do
      options[k] = pandoc.utils.stringify(v)
    end
  end

  local tikzFilter = tikz_walker(options)
  local filteredBlocks = pandoc.walk_block(pandoc.Div(doc.blocks), tikzFilter).content
  return pandoc.Pandoc(filteredBlocks, doc.meta)
end
