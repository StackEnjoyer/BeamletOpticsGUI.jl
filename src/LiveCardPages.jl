#=
Pages of the cards of the live view ("Pose", "Results", "Properties") per type of object
=#

# The pages of a card in the order of the page bar, with their labels
const _PAGES = (:pose => "Pose", :results => "Results", :properties => "Properties")

"""
    _has_page(obj, ::Val{page}) -> Bool

Whether the card of `obj` has the `page`: `:pose` (the rows of [`card_rows`](@ref) and, for the
selection, the keyboard step and the mode) for every object, `:results` for an object with a view
(see `_has_view`, e.g. a `Detector`), `:properties` for an object with a property list (see
`_has_properties`). Add a method for a type to give its card another set of pages.
"""
_has_page(_, ::Val{:pose}) = true
_has_page(obj, ::Val{:results}) = _has_view(obj)
_has_page(obj, ::Val{:properties}) = _has_properties(obj)

"""
    _card_pages(obj) -> Tuple{Vararg{Symbol}}

The pages of the card of `obj`, in the order of the page bar, see `_has_page`: e.g.
`(:pose, :properties)` for a mirror and `(:pose, :results, :properties)` for a detector. A card
with a single page shows no page bar.
"""
_card_pages(obj) = Tuple(page for (page, _) in _PAGES if _has_page(obj, Val(page)))

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
