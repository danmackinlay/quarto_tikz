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

local function debugPrint(obj)
  print(serialize(obj))
end

local function debugLog(obj)
  quarto.log.output(serialize(obj))
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

local function createTexFile(tikzCode, tmpdir, outputFile)
  local template = [[
    \documentclass[tikz]{standalone}
    \usepackage{amsmath}
    \usetikzlibrary{matrix}
    \begin{document}
    \begin{tikzpicture}
    %s
    \end{tikzpicture}
    \end{document}
  ]]

  local texCode = string.format(template, tikzCode)
  local texFile = pandoc.path.join({ tmpdir, outputFile .. ".tex" })
  local file = io.open(texFile, "w")
  file:write(texCode)
  file:close()

  return texFile
end

local function tikzToSvg(tikzCode, tmpdir, outputFile)
  local texFile = createTexFile(tikzCode, tmpdir, outputFile)
  local dviFile = pandoc.path.join({ tmpdir, outputFile .. ".dvi" })
  local svgFile = pandoc.path.join({ tmpdir, outputFile .. ".svg" })

  os.execute("latex -interaction=nonstopmode -output-directory=" .. tmpdir .. " " .. texFile)
  os.execute("dvisvgm " .. dviFile .. " -n -o " .. svgFile)
  os.remove(texFile)
  os.remove(dviFile)

  return svgFile
end

local function tikzToPdf(tikzCode, tmpdir, outputFile)
  local texFile = createTexFile(tikzCode, tmpdir, outputFile)
  local pdfFile = pandoc.path.join({ tmpdir, outputFile .. ".pdf" })

  os.execute("pdflatex -interaction=nonstopmode -output-directory=" .. tmpdir .. " " .. texFile)
  os.remove(texFile)

  return pdfFile
end

local function render_tikz(globalOptions)
  local filter = {
    CodeBlock = function(cb)
      if not cb.classes:includes('tikz') or cb.text == nil then
        return nil
      end

      counter = counter + 1

      -- Initialise options table
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

      -- Set default filename
      if options.filename == nil then
        options.filename = "tikz-output-" .. counter
      end

      -- Set the default format to pdf since svg is not supported in PDF output
      if options.format == TikzFormat.svg and quarto.doc.is_format("latex") then
        options.format = TikzFormat.pdf
      end
      -- Set the default embed_mode to link if the quarto format is not html or the figure format is pdf
      if not quarto.doc.is_format("html") or options.format == TikzFormat.pdf then
        options.embed_mode = EmbedMode.link
      end

      -- Set the default folder to ./images when embed_mode is link
      if options.folder == nil and options.embed_mode == EmbedMode.link then
        options.folder = "./images"
      end
      local result = pandoc.system.with_temporary_directory('tikz-convert', function(tmpdir)
        local outputPath
        local tempOutputPath

        if options.folder ~= nil then
          os.execute("mkdir -p " .. options.folder)
          tempOutputPath = pandoc.path.join({ tmpdir, options.filename .. "." .. options.format })
          outputPath = options.folder .. "/" .. options.filename .. "." .. options.format
        else
          tempOutputPath = pandoc.path.join({ tmpdir, options.filename .. "." .. options.format })
          outputPath = tempOutputPath
        end

        if quarto.doc.isFormat("html") then
          tikzToSvg(cb.text, tmpdir, options.filename)
        elseif quarto.doc.isFormat("pdf") then
          tikzToPdf(cb.text, tmpdir, options.filename)
        else
          print("Error: Unsupported format")
          return nil
        end
        -- move the file from the temporary directory to the project directory
        if tempOutputPath ~= outputPath then
          os.rename(tempOutputPath, outputPath)
        end

        if options.embed_mode == EmbedMode.link then
          return outputPath
        else
          local file = io.open(outputPath, "rb")
          local data
          if file then
            data = file:read('*all')
            file:close()
          end
          os.remove(outputPath)

          if options.embed_mode == EmbedMode.raw then
            return data
          elseif options.embed_mode == EmbedMode.inline then
            if options.format == "svg" then
              return "data:image/svg+xml;base64," .. quarto.base64.encode(data)
            elseif options.format == "pdf" then
              return "data:application/pdf;base64," .. quarto.base64.encode(data)
            else
              debugLog("Error: Unsupported format")
              return nil
            end
          end
        end
      end)

      local output
      if options.embed_mode == EmbedMode.raw then
        output = pandoc.Div({ pandoc.RawInline("html", result) })
        if options.width ~= nil then
          output.attributes.style = "width: " .. options.width .. ";"
        end
        if options.height ~= nil then
          output.attributes.style = output.attributes.style .. "height: " .. options.height .. ";"
        end
      else
        local image = pandoc.Image({}, result)
        if options.width ~= nil then
          image.attributes.width = options.width
        end
        if options.height ~= nil then
          image.attributes.height = options.height
        end
        if options.caption ~= '' then
          image.caption = pandoc.Str(options.caption)
        end
        output = pandoc.Para({ image })
      end

      return output
    end
  }
  return filter
end

function Pandoc(doc)
  local options = {
    format = TikzFormat.svg,
    folder = nil,
    filename = nil,
    caption = '',
    width = nil,
    height = nil,
    embed_mode = EmbedMode.inline
  }

  -- Process global attributes
  local globalOptions = doc.meta["tikz"]
  if type(globalOptions) == "table" then
    for k, v in pairs(globalOptions) do
      options[k] = pandoc.utils.stringify(v)
    end
  end

  return doc:walk(render_tikz(options))
end
