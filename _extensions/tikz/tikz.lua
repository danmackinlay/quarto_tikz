--[[
tikz.lua - A Lua filter to process TikZ code blocks and generate figures.

Based on the style of 'quarto_diagram/diagram.lua', adapted for TikZ diagrams.
]]

PANDOC_VERSION:must_be_at_least '3.0'

local pandoc                   = require 'pandoc'
local system                   = require 'pandoc.system'
local utils                    = require 'pandoc.utils'

local stringify                = utils.stringify
local with_temporary_directory = system.with_temporary_directory
local with_working_directory   = system.with_working_directory

-- Functions to read and write files
local function read_file(filepath)
  local fh = io.open(filepath, 'rb')
  local contents = fh:read('a')
  fh:close()
  return contents
end

local function write_file(filepath, content)
  local fh = io.open(filepath, 'wb')
  fh:write(content)
  fh:close()
end

-- Returns a filter-specific directory in which cache files can be stored, or nil if not available.
local function cachedir()
  local cache_home = os.getenv 'XDG_CACHE_HOME'
  if not cache_home or cache_home == '' then
    local user_home = system.os == 'windows'
        and os.getenv 'USERPROFILE'
        or os.getenv 'HOME'

    if not user_home or user_home == '' then
      return nil
    end
    cache_home = pandoc.path.join { user_home, '.cache' } or nil
  end

  -- Create filter cache directory
  return pandoc.path.join { cache_home, 'tikz-diagram-filter' }
end

local image_cache = nil -- Path holding the image cache, or `nil` if the cache is not used.

-- Function to parse properties from code comments
local function properties_from_code(code, comment_start)
  local props = {}
  local pattern = comment_start:gsub('%p', '%%%1') .. '| ?' ..
      '([-_%w]+): ([^\n]*)\n'
  for key, value in code:gmatch(pattern) do
    if key == 'fig-attr' then
      -- Handle nested attributes for fig-attr
      local attr_value = ''
      local subpattern = comment_start:gsub('%p', '%%%1') .. '|   ([^\n]+)\n'
      for subvalue in code:gmatch(subpattern) do
        attr_value = attr_value .. subvalue .. '\n'
      end
      props[key] = pandoc.read(attr_value, 'yaml').meta
    else
      props[key] = value
    end
  end
  return props
end

-- Function to process code block attributes and options
local function diagram_options(cb)
  local attribs = properties_from_code(cb.text, '%%')
  for key, value in pairs(cb.attributes) do
    attribs[key] = value
  end

  local alt
  local caption
  local fig_attr = attribs['fig-attr'] or { id = cb.identifier }
  local filename
  local image_attr = {}
  local user_opt = {}

  for attr_name, value in pairs(attribs) do
    if attr_name == 'alt' then
      alt = value
    elseif attr_name == 'caption' then
      -- Read caption attribute as Markdown
      caption = pandoc.read(value).blocks
    elseif attr_name == 'filename' then
      filename = value
    elseif attr_name == 'label' then
      fig_attr.id = value
    elseif attr_name == 'name' then
      fig_attr.name = value
    elseif attr_name == 'fig-attr' then
      -- Already handled
    else
      -- Check for prefixed attributes
      local prefix, key = attr_name:match '^(%a+)%-(%a[-%w]*)$'
      if prefix == 'fig' then
        fig_attr[key] = value
      elseif prefix == 'image' or prefix == 'img' then
        image_attr[key] = value
      elseif prefix == 'opt' then
        user_opt[key] = value
      else
        -- Use as image attribute
        image_attr[attr_name] = value
      end
    end
  end

  return {
    ['alt'] = alt or {},
    ['caption'] = caption,
    ['fig-attr'] = fig_attr,
    ['filename'] = filename,
    ['image-attr'] = image_attr,
    ['opt'] = user_opt,
  }
end

-- Function to get cached image
local function get_cached_image(hash)
  if not image_cache then
    return nil
  end
  local filename = hash .. '.svg' -- We will use SVG output
  local imgpath = pandoc.path.join { image_cache, filename }
  local success, imgdata = pcall(read_file, imgpath)
  if success then
    return imgdata, 'image/svg+xml'
  end
  return nil
end

-- Function to cache image
local function cache_image(codeblock, imgdata)
  -- Do nothing if caching is disabled or not possible.
  if not image_cache then
    return
  end
  local filename = pandoc.sha1(codeblock.text) .. '.svg'
  local imgpath = pandoc.path.join { image_cache, filename }
  write_file(imgpath, imgdata)
end

-- Function to compile TikZ code to SVG
local function compile_tikz_to_svg(code, user_opts)
  return with_temporary_directory("tikz", function(tmpdir)
    return with_working_directory(tmpdir, function()
      -- Define file names:
      local tikz_file = pandoc.path.join { tmpdir, "tikz-image.tex" }
      local pdf_file = pandoc.path.join { tmpdir, "tikz-image.pdf" }
      local svg_file = pandoc.path.join { tmpdir, "tikz-image.svg" }

      -- Build the LaTeX document
      local tikz_template = pandoc.template.compile [[
\documentclass{standalone}
\usepackage{tikz}
$for(header-includes)$
$it$
$endfor$
$additional-packages$
\begin{document}
$body$
\end{document}
]]
      local meta = {
        ['header-includes'] = user_opts['header-includes'],
        ['additional-packages'] = { pandoc.RawInline(
          'latex',
          stringify(user_opts['additional-packages'] or '')
        ) },
      }
      local tex_code = pandoc.write(
        pandoc.Pandoc({ pandoc.RawBlock('latex', code) }, meta),
        'latex',
        { template = tikz_template }
      )
      write_file(tikz_file, tex_code)

      -- Execute the LaTeX compiler:
      local success, result = pcall(
        pandoc.pipe,
        'pdflatex',
        { '-interaction=nonstopmode', '-output-directory', tmpdir, tikz_file },
        ''
      )
      if not success then
        error("Error running pdflatex:\n" .. tostring(result))
      end

      -- Convert PDF to SVG using Inkscape
      local args = {
        '--export-type=svg',
        '--export-plain-svg',
        '--export-filename=' .. svg_file,
        pdf_file
      }
      local success, result = pcall(pandoc.pipe, 'inkscape', args, '')
      if not success then
        error("Error running inkscape:\n" .. tostring(result))
      end

      -- Read the SVG file
      local imgdata = read_file(svg_file)
      return imgdata, 'image/svg+xml'
    end)
  end)
end

-- Function to process code blocks and generate figures
local function code_to_figure(conf)
  return function(block)
    if block.t ~= 'CodeBlock' then
      return nil
    end

    -- Check if it's a TikZ code block
    if not block.classes:includes('tikz') then
      return nil
    end

    -- Get options from code block
    local dgr_opt = diagram_options(block)

    -- Check if image is cached
    local imgdata, imgtype
    if conf.cache then
      imgdata, imgtype = get_cached_image(
        pandoc.sha1(block.text)
      )
    end

    if not imgdata or not imgtype then
      -- No cached image; compile TikZ code
      local success
      success, imgdata, imgtype = pcall(compile_tikz_to_svg, block.text, dgr_opt.opt)
      if not success then
        error("Error compiling TikZ code:\n" .. tostring(imgdata))
      end

      -- Cache the image
      cache_image(block, imgdata)
    end

    -- Use the block's filename attribute or create a new name by hashing the image content.
    local basename = dgr_opt.filename or pandoc.sha1(imgdata)
    local fname = basename .. '.svg'

    -- Store the data in the media bag:
    pandoc.mediabag.insert(fname, 'image/svg+xml', imgdata)

    -- Create the image object.
    local image = pandoc.Image(dgr_opt.alt, fname, "", dgr_opt['image-attr'])

    -- Create a figure if the diagram has a caption; otherwise return just the image.
    return dgr_opt.caption and
        pandoc.Figure(
          pandoc.Plain { image },
          dgr_opt.caption,
          dgr_opt['fig-attr']
        ) or
        pandoc.Plain { image }
  end
end

-- Function to configure the filter based on metadata and format
local function configure(meta, format_name)
  local conf = meta.tikz or {}
  local format = format_name
  meta.tikz = nil -- Remove tikz metadata to avoid processing it further

  -- cache for image files
  if conf.cache == true then
    image_cache = conf['cache-dir']
        and stringify(conf['cache-dir'])
        or cachedir()
    pandoc.system.make_directory(image_cache, true)
  else
    image_cache = nil
  end

  return {
    cache = image_cache and true,
    image_cache = image_cache,
  }
end

return {
  {
    Pandoc = function(doc)
      local conf = configure(doc.meta, FORMAT)
      return doc:walk {
        CodeBlock = code_to_figure(conf),
      }
    end
  }
}
