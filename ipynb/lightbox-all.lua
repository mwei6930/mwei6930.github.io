-- Quarto handles block images itself. This filter wraps images embedded inside
-- lists, tables, formulas, or prose while preserving images that are links.
local gallery_index = 0

local inline_containers = {
  Cite = true,
  Emph = true,
  Quoted = true,
  SmallCaps = true,
  Span = true,
  Strikeout = true,
  Strong = true,
  Subscript = true,
  Superscript = true,
  Underline = true,
}

local function has_class(element, target)
  for _, class_name in ipairs(element.classes) do
    if class_name == target then
      return true
    end
  end

  return false
end

local function wrap_images(inlines)
  for index, inline in ipairs(inlines) do
    if inline.t == "Image" and not has_class(inline, "nolightbox") then
      gallery_index = gallery_index + 1
      local attributes = {
        ["data-gallery"] = "quarto-lightbox-inline-" .. gallery_index,
      }
      local title = inline.title or pandoc.utils.stringify(inline.caption)

      inlines[index] = pandoc.Link(
        { inline },
        inline.src,
        title,
        pandoc.Attr("", { "lightbox" }, attributes)
      )
    elseif inline.t ~= "Link" and inline_containers[inline.t] then
      inline.content = wrap_images(inline.content)
    end
  end

  return inlines
end

function Para(paragraph)
  paragraph.content = wrap_images(paragraph.content)
  return paragraph
end

function Plain(plain)
  plain.content = wrap_images(plain.content)
  return plain
end

local function page_language(metadata)
  local language = pandoc.utils.stringify(metadata.lang or "")
  return language:lower():match("^zh") ~= nil
end

local function first_link(block)
  if block.t ~= "Para" and block.t ~= "Plain" then
    return nil
  end

  for _, inline in ipairs(block.content) do
    if inline.t == "Link" then
      return inline
    end
  end

  return nil
end

local function is_guideline_link(block)
  local link = first_link(block)
  if not link then
    return false
  end

  local label = pandoc.utils.stringify(block):lower()
  return label:find("guideline", 1, true)
      or label:find("overview", 1, true)
      or label:find("总览", 1, true)
      or label:find("指南", 1, true)
end

local function page_navigation(existing_block, chinese)
  local home_label = chinese and "博客首页" or "Hexo Home"
  local navigation_label = chinese and "页面导航" or "Page navigation"
  local inlines = {
    -- Raw HTML keeps the root URL as "/" instead of Pandoc normalizing it to ".".
    pandoc.RawInline("html", '<a href="/">' .. home_label .. "</a>"),
  }

  if existing_block then
    table.insert(inlines, pandoc.Space())
    table.insert(
      inlines,
      pandoc.Span(
        { pandoc.Str("/") },
        pandoc.Attr("", { "blog-page-nav-separator" }, { ["aria-hidden"] = "true" })
      )
    )
    table.insert(inlines, pandoc.Space())

    for _, inline in ipairs(existing_block.content) do
      table.insert(inlines, inline)
    end
  end

  return pandoc.Div(
    { pandoc.Plain(inlines) },
    pandoc.Attr(
      "",
      { "blog-page-nav" },
      { ["aria-label"] = navigation_label }
    )
  )
end

function Pandoc(document)
  local blocks = {}
  local index = 1
  local chinese = page_language(document.meta)

  while index <= #document.blocks do
    local block = document.blocks[index]
    table.insert(blocks, block)

    if block.t == "Div" and has_class(block, "blog-language-switch") then
      local following = document.blocks[index + 1]

      if following and following.t == "Div"
          and has_class(following, "blog-page-nav") then
        -- Keep an explicitly authored navigation block unchanged.
      elseif following and is_guideline_link(following) then
        table.insert(blocks, page_navigation(following, chinese))
        index = index + 1
      else
        table.insert(blocks, page_navigation(nil, chinese))
      end
    end

    index = index + 1
  end

  return pandoc.Pandoc(blocks, document.meta)
end
