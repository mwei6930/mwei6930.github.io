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
