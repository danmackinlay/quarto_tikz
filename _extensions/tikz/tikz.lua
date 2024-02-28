
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

-- Global options table
local globalOptions = {
  format = TikzFormat.svg,
  folder = nil,
  filename = pandoc.utils.stringify("tikz-output"),
  caption = '',
  width = nil,
  height = nil,
  embed_mode = EmbedMode.inline,
  cache = nil,
  debug = false
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

-- Debug functions
local function debugTablePrint(obj)
  if globalOptions.debug then
    print(serialize(obj))
  end
end

local function debugTableLog(obj)
  if globalOptions.debug then
    quarto.log.output(serialize(obj))
  end
end

local function debugPrint(obj)
  if globalOptions.debug then
    print(obj)
  end
end

local function debugLog(obj)
  if globalOptions.debug then
    quarto.log.output(obj)
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
  debugLog(texCode)
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
local function processOptions(cb)
  local localOptions = copyTable(globalOptions)

  -- Process codeblock attributes
  for k, v in pairs(cb.attributes) do
    localOptions[k] = v
  end

  -- Transform options
  if localOptions.format ~= nil and type(localOptions.format) == "string" then
    assert(TikzFormat[localOptions.format] ~= nil,
      "Invalid format: " .. localOptions.format .. ". Options are: " .. serialize(TikzFormat))
    localOptions.format = TikzFormat[localOptions.format]
  end
  if localOptions.embed_mode ~= nil and type(localOptions.embed_mode) == "string" then
    assert(EmbedMode[localOptions.embed_mode] ~= nil,
      "Invalid embed_mode: " .. localOptions.embed_mode .. ". Options are: " .. serialize(EmbedMode))
    localOptions.embed_mode = EmbedMode[localOptions.embed_mode]
  end

  -- Set default values
  localOptions.filename = (localOptions.filename or "tikz-output") .. "-" .. counter
  if localOptions.format == TikzFormat.svg and quarto.doc.is_format("latex") then
    localOptions.format = TikzFormat.pdf
  end
  if not quarto.doc.is_format("html") or localOptions.format == TikzFormat.pdf then
    localOptions.embed_mode = EmbedMode.link
  end
  if localOptions.folder == nil and localOptions.embed_mode == EmbedMode.link then
    localOptions.folder = "./images"
  end

  -- Set cache path
  localOptions.cache = localOptions.cache or nil

  return localOptions
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
      outputPath = cachePath
    else
      -- Generate the output
      if quarto.doc.isFormat("html") then
        tikzToSvg(cb.text, tmpdir, options.filename, options.scale, options.libraries)
      elseif quarto.doc.isFormat("pdf") then
        tikzToPdf(cb.text, tmpdir, options.filename, options.scale, options.libraries)
      else
        quarto.log.output("Error: Unsupported format")
        return nil
      end

      if tempOutputPath ~= outputPath then
        os.rename(tempOutputPath, outputPath)
      end

      -- Save the result to the cache
      if options.cache ~= nil then
        os.execute("mkdir -p " .. pandoc.path.directory(cachePath))
        os.execute("cp " .. outputPath .. " " .. cachePath)
      end
    end
  end

  -- Read the data
  local file = io.open(outputPath, "rb")
  local data = file and file:read('*all')
  if file then file:close() end

  if options.embed_mode == EmbedMode.link then
    return outputPath
  else
    -- Prepare the data for embedding
    local mimeType = (options.format == "svg" and "image/svg+xml") or "application/pdf"
    local encodedData = quarto.base64.encode(data)
    return "data:" .. mimeType .. ";base64," .. encodedData
  end
end

-- Main function to create the TikZ filter
local function tikz_walker()
  return {
    CodeBlock = function(cb)
      if not cb.classes:includes('tikz') or cb.text == nil then
        return nil
      end

      counter = counter + 1
      local localOptions = processOptions(cb)

      local result = pandoc.system.with_temporary_directory('tikz-convert', function(tmpdir)
        return renderTikz(cb, localOptions, tmpdir)
      end)

      local caption = localOptions.caption ~= '' and { pandoc.Str(localOptions.caption) } or nil
      local figure = pandoc.Figure({ pandoc.Image({}, result) }, caption)
      if localOptions.width ~= nil then
        figure.content[1].attributes.width = localOptions.width
      end
      if localOptions.height ~= nil then
        figure.content[1].attributes.height = localOptions.height
      end
      -- Preserve the ID of the original code block
      if cb.identifier ~= nil then
        figure.identifier = cb.identifier
      end
      return figure
    end
  }
end

-- Main function to create the TikZ filter
function Pandoc(doc)
  -- Process global attributes
  local docGlobalOptions = doc.meta["tikz"]
  if type(docGlobalOptions) == "table" then
    for k, v in pairs(docGlobalOptions) do
      globalOptions[k] = pandoc.utils.stringify(v)
    end
  end

  -- Set debug option
  globalOptions.debug = (globalOptions.debug and true) or false

  debugTableLog(globalOptions)

  local tikzFilter = tikz_walker()
  local filteredBlocks = pandoc.walk_block(pandoc.Div(doc.blocks), tikzFilter).content
  return pandoc.Pandoc(filteredBlocks, doc.meta)
end
