#=
Pages of the cards of the live view ("Pose", "Color", "Edit", "Results", "Properties") per type of
object
=#

# The pages of a card in the order of the page bar, with their labels
const _PAGES = (:pose => "Pose", :color => "Color", :edit => "Edit", :results => "Results",
    :properties => "Properties")

"""
    _has_page(obj, ::Val{page}) -> Bool

Whether the card of `obj` has the `page`: `:pose` (the rows of [`card_rows`](@ref) and, for the
selection, the keyboard step and the mode) for every object, `:color` for a beam or a beam group
(the color and the opacity in which it is drawn, see `_color_rows`), `:results` for an object with
a view (see `_has_view`, e.g. a `Detector`), `:properties` for an object with a property list (see
`_has_properties`). Add a method for a type to give its card another set of pages.
"""
_has_page(_, ::Val{:pose}) = true
_has_page(_, ::Val{:color}) = false
# Only with the view, which knows what was built from the catalog, see `_card_pages(gui, obj)`
_has_page(_, ::Val{:edit}) = false
_has_page(obj, ::Val{:results}) = _has_view(obj)
_has_page(obj, ::Val{:properties}) = _has_properties(obj)

"""
    _card_pages(obj) -> Tuple{Vararg{Symbol}}

The pages of the card of `obj`, in the order of the page bar, see `_has_page`: e.g.
`(:pose, :properties)` for a mirror, `(:pose, :results, :properties)` for a detector and
`(:pose, :color, :properties)` for a source. A card with a single page shows no page bar.
"""
_card_pages(obj) = Tuple(page for (page, _) in _PAGES if _has_page(obj, Val(page)))

"""
    _page_rows(obj, page) -> Tuple

The rows of the card of `obj` on its `page`, as declarations like those of [`card_rows`](@ref): the
rows of the page "Color" (see `_color_rows`), otherwise those of the page "Pose" (see `_card_rows`),
which stay built on the pages without rows.
"""
_page_rows(obj, page::Symbol) = _page_rows(obj, Val(page))
_page_rows(obj, ::Val) = _card_rows(obj)

"""
    _card_pages(gui, obj) -> Tuple{Vararg{Symbol}}
    _page_rows(gui, obj, page) -> Tuple

The pages of the card of `obj` in the `gui` and the rows of its `page`: those of its type (see
`_card_pages(obj)` and `_page_rows(obj, page)`) and the page "Edit" of a component or source that
was built from an entry of the catalog, with the form of the entry, see `_editable` and
`_edit_rows`.
"""
_card_pages(gui, obj) = Tuple(page for (page, _) in _PAGES if _has_page(gui, obj, Val(page)))
_has_page(_, obj, page::Val) = _has_page(obj, page)
_page_rows(gui, obj, page::Symbol) = _page_rows(gui, obj, Val(page))
_page_rows(_, obj, page::Val) = _page_rows(obj, page)

"""Whether the `page` of a card shows declared rows, see `_page_rows`."""
_shows_rows(page::Symbol) = page === :pose || page === :color || page === :edit

"""
    _default_page(obj) -> Symbol

The page that the card of `obj` shows when it gets this object: the results of an object with a
view, such that a click on a detector shows what it measures, otherwise the pose.
"""
_default_page(obj) = _has_view(obj) ? :results : :pose

"""Label of the `page` of a card in the page bar."""
_page_label(page::Symbol) = last(_PAGES[findfirst(p -> first(p) === page, _PAGES)])

"""
    _page_bar!(pos, theme, pages; selected = first(pages)) -> _Segmented

The page bar of a card at the grid position `pos`: a segmented control of the `pages` (see
`_card_pages`) in the color tokens `theme`, whose `selected` observable is the shown page.
"""
_page_bar!(pos, theme::NamedTuple, pages; selected::Symbol = first(pages)) =
    _Segmented(pos, Pair{Symbol, String}[page => _page_label(page) for page in pages]; theme, selected)
