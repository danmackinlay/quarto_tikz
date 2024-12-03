--[[
tikz.lua - A Lua filter to process TikZ code blocks and generate figures.

Based on the style of 'quarto_diagram/diagram.lua', adapted for TikZ diagrams.
]]

PANDOC_VERSION:must_be_at_least '3.0'

local pandoc = require 'pandoc'
local system = require 'pandoc.system'
local utils  = require 'pandoc.utils'

local stringify = utils.stringify
local with_temporary_directory = system.with_temporary_directory
local with_working_directory = system.with_working_directory

-- Functions to read and write files
local function read_file (filepath)
  local fh = io.open(filepath, 'rb')
  if not fh then return nil end
  local contents = fh:read('a')
  fh:close()
  return contents
end

local function write_file (filepath, content)
  local fh = io.open(filepath, 'wb')
  if not fh then return false end
  fh:write(content)
  fh:close()
  return true
end

-- Function to check if a command exists
local function check_dependency(cmd)
  local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
  local result = handle:read("*a")
  handle:close()
  return result ~= ""
end

-- Returns a filter-specific directory in which cache files can be stored, or nil if not available.
local function cachedir ()
  local cache_home = os.getenv 'XDG_CACHE_HOME'
  if not cache_home or cache_home == '' then
    local user_home = system.os == 'windows'
      and os.getenv 'USERPROFILE'
      or os.getenv 'HOME'

    if not user_home or user_home == '' then
      return nil
    end
    cache_home = pandoc.path.join { user_home, '.cache' }
  end

  -- Create filter cache directory
  local cache_dir = pandoc.path.join { cache_home, 'tikz-diagram-filter' }
  pandoc.system.make_directory(cache_dir, true)
  return cache_dir
end

local image_cache = nil  -- Path holding the image cache, or `nil` if the cache is not used.

-- Function to parse properties from code comments
local function properties_from_code (code, comment_start)
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
      -- Parse the YAML-like subattributes
      local parsed = pandoc.read(attr_value, 'yaml').blocks
      if #parsed > 0 then
        props[key] = pandoc.utils.block_to_lua(parsed[1])
      end
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
      caption = pandoc.read(value, 'markdown').blocks
    elseif attr_name == 'filename' then
      filename = value
    elseif attr_name == 'additionalPackages' then
      user_opt['additional-packages'] = value
    elseif attr_name == 'header-includes' then
      user_opt['header-includes'] = value
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
local function get_cached_image (hash, options)
  if not image_cache then
    return nil
  end
  -- Include options in the hash to ensure cache invalidation when options change
  local cache_key = pandoc.sha1(hash .. stringify(options))
  local filename = cache_key .. '.svg' -- We will use SVG output
  local imgpath = pandoc.path.join { image_cache, filename }
  local imgdata = read_file(imgpath)
  if imgdata then
    return imgdata, 'image/svg+xml'
  end
  return nil
end

-- Function to cache image
local function cache_image (hash, options, imgdata)
  -- Do nothing if caching is disabled or not possible.
  if not image_cache then
    return
  end
  local cache_key = pandoc.sha1(hash .. stringify(options))
  local filename = cache_key .. '.svg'
  local imgpath = pandoc.path.join { image_cache, filename }
  write_file(imgpath, imgdata)
end

-- Function to compile TikZ code to SVG
local function compile_tikz_to_svg(code, user_opts, conf, basename)  -- Added conf and basename parameters
  -- Ensure required dependencies are available
  if not check_dependency('pdflatex') then
    error("pdflatex not found. Please install LaTeX to compile TikZ diagrams.")
  end
  if not check_dependency('inkscape') then
    error("Inkscape not found. Please install Inkscape to convert PDFs to SVG.")
  end

  local function process_in_dir(dir)
    return with_working_directory(dir, function()
      -- Define file names:
      -- Use the provided basename or default to "tikz-image"
      local base_filename = basename or "tikz-image"
      local tikz_file = base_filename .. ".tex"
      local pdf_file = base_filename .. ".pdf"
      local svg_file = base_filename .. ".svg"

      -- Build the LaTeX document
      local tikz_template = pandoc.template.compile [[
\documentclass[tikz]{standalone}
% \usepackage{tikz} % already loaded by the documentclass
$additional-packages$
$for(header-includes)$
$it$
$endfor$
\begin{document}
$body$
\end{document}
      ]]
      local meta = {
        ['header-includes'] = { pandoc.RawInline(
          'latex',
          stringify(user_opts['header-includes'] or '')
        ) },
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
      local success, latex_result = pcall(
        pandoc.pipe,
        'pdflatex',
        { '-interaction=nonstopmode', tikz_file },
        ''
      )
      if not success then
        local log_file = base_filename .. ".log"
        local log_content = read_file(log_file) or ""
        error("Error compiling TikZ figure '" .. base_filename .. "':\n" ..
          tostring(latex_result) .. "\nLaTeX Log:\n" .. log_content ..
          "\nTikZ Code:\n" .. code)
      end

      -- Convert PDF to SVG using Inkscape
      local args = {
        '--pages=1',
        '--export-area-drawing',
        '--export-type=svg',
        '--export-plain-svg',
        '--export-margin=0',
        '--export-filename=' .. svg_file,
        pdf_file
      }
      local success_inkscape, inkscape_result = pcall(pandoc.pipe, 'inkscape', args, '')
      if not success_inkscape then
        error("Error converting PDF to SVG for TikZ figure '" .. base_filename .. "':\n" ..
          tostring(inkscape_result) .. "\nTikZ Code:\n" .. code)
      end

      -- Read the SVG file
      local imgdata = read_file(svg_file)
      if not imgdata then
        error("Failed to read generated SVG file for TikZ figure '" .. base_filename .. "'.\nTikZ Code:\n" .. code)
      end
      return imgdata, 'image/svg+xml'
    end)
  end

  if conf.save_tex then
    local dir = conf.tex_dir
    -- Use the basename or hash to create a subdirectory
    local subdir_name = basename or pandoc.sha1(code)
    local diagram_dir = pandoc.path.join { dir, subdir_name }
    pandoc.system.make_directory(diagram_dir, true)
    return process_in_dir(diagram_dir)
  else
    return with_temporary_directory("tikz", function(tmpdir)
      return process_in_dir(tmpdir)
    end)
  end
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

    -- Get basename for file naming
    local basename = dgr_opt.filename or pandoc.sha1(block.text)

    -- Check if image is cached
    local hash = block.text
    local imgdata, imgtype = nil, nil
    if conf.cache then
      imgdata, imgtype = get_cached_image(hash, dgr_opt.opt)
    end

    if not imgdata or not imgtype then
      -- No cached image; compile TikZ code
      local success, result = pcall(function()
        return compile_tikz_to_svg(block.text, dgr_opt.opt, conf, basename) -- Pass conf and basename
      end)
      if not success then
        quarto.log.error("Error compiling TikZ figure '" .. basename .. "': " .. tostring(result))
        return nil -- Return the original block unchanged
      end
      imgdata, imgtype = result, 'image/svg+xml'

      -- Cache the image
      cache_image(hash, dgr_opt.opt, imgdata)
    end

    -- Use the block's filename attribute or create a new name by hashing the image content.
    local fname = basename .. '.svg'

    -- Store the data in the mediabag:
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
local function configure (meta, format_name)
  local conf = meta.tikz or {}
  local format = format_name
  meta.tikz = nil  -- Remove tikz metadata to avoid processing it further

  -- cache for image files
  if conf.cache == true then
    image_cache = conf['cache-dir']
      and stringify(conf['cache-dir'])
      or cachedir()
    if image_cache then
      pandoc.system.make_directory(image_cache, true)
    end
  else
    image_cache = nil
  end

  -- Handle save-tex option
  local save_tex = conf['save-tex'] or false
  local tex_dir = nil
  if save_tex then
    if image_cache then
      -- Both cache and save-tex are enabled; raise a warning and disable save-tex
      quarto.log.warning("Both 'cache' and 'save-tex' are enabled. Disabling 'save-tex' since caching is active.")
      save_tex = false
    else
      tex_dir = conf['tex-dir']
      if tex_dir then
        tex_dir = pandoc.utils.stringify(tex_dir)
      else
        -- Use a default directory, e.g., 'tikz-tex'
        tex_dir = 'tikz-tex'
      end
      pandoc.system.make_directory(tex_dir, true)
    end
  end

  return {
    cache = image_cache and true,
    image_cache = image_cache,
    save_tex = save_tex,
    tex_dir = tex_dir,
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
