// Populate the sidebar
//
// This is a script, and not included directly in the page, to control the total size of the book.
// The TOC contains an entry for each page, so if each page includes a copy of the TOC,
// the total size of the page becomes O(n**2).
class MDBookSidebarScrollbox extends HTMLElement {
    constructor() {
        super();
    }
    connectedCallback() {
        this.innerHTML = '<ol class="chapter"><li class="chapter-item expanded affix "><a href="index.html">Introduction</a></li><li class="chapter-item expanded "><a href="terraform_rules.html"><strong aria-hidden="true">1.</strong> Terraform Rules</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="terraform/terraform_binary.html"><strong aria-hidden="true">1.1.</strong> terraform_binary</a></li><li class="chapter-item expanded "><a href="terraform/terraform_fmt_aspect.html"><strong aria-hidden="true">1.2.</strong> terraform_fmt_aspect</a></li><li class="chapter-item expanded "><a href="terraform/terraform_fmt_test.html"><strong aria-hidden="true">1.3.</strong> terraform_fmt_test</a></li><li class="chapter-item expanded "><a href="terraform/terraform_module.html"><strong aria-hidden="true">1.4.</strong> terraform_module</a></li><li class="chapter-item expanded "><a href="terraform/terraform_modules_lock.html"><strong aria-hidden="true">1.5.</strong> terraform_modules_lock</a></li><li class="chapter-item expanded "><a href="terraform/terraform_provider.html"><strong aria-hidden="true">1.6.</strong> terraform_provider</a></li><li class="chapter-item expanded "><a href="terraform/terraform_provider_group.html"><strong aria-hidden="true">1.7.</strong> terraform_provider_group</a></li><li class="chapter-item expanded "><a href="terraform/terraform_test.html"><strong aria-hidden="true">1.8.</strong> terraform_test</a></li><li class="chapter-item expanded "><a href="terraform/terraform_validate_aspect.html"><strong aria-hidden="true">1.9.</strong> terraform_validate_aspect</a></li><li class="chapter-item expanded "><a href="terraform/terraform_validate_test.html"><strong aria-hidden="true">1.10.</strong> terraform_validate_test</a></li><li class="chapter-item expanded "><a href="terraform/extensions.html"><strong aria-hidden="true">1.11.</strong> extensions</a></li></ol></li><li class="chapter-item expanded "><a href="terraform/settings.html"><strong aria-hidden="true">2.</strong> Terraform Settings</a></li><li class="chapter-item expanded "><a href="opentofu_rules.html"><strong aria-hidden="true">3.</strong> OpenTofu Rules</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="opentofu/opentofu_binary.html"><strong aria-hidden="true">3.1.</strong> opentofu_binary</a></li><li class="chapter-item expanded "><a href="opentofu/opentofu_fmt_test.html"><strong aria-hidden="true">3.2.</strong> opentofu_fmt_test</a></li><li class="chapter-item expanded "><a href="opentofu/opentofu_module.html"><strong aria-hidden="true">3.3.</strong> opentofu_module</a></li><li class="chapter-item expanded "><a href="opentofu/opentofu_provider.html"><strong aria-hidden="true">3.4.</strong> opentofu_provider</a></li><li class="chapter-item expanded "><a href="opentofu/opentofu_provider_group.html"><strong aria-hidden="true">3.5.</strong> opentofu_provider_group</a></li><li class="chapter-item expanded "><a href="opentofu/opentofu_test.html"><strong aria-hidden="true">3.6.</strong> opentofu_test</a></li><li class="chapter-item expanded "><a href="opentofu/opentofu_validate_test.html"><strong aria-hidden="true">3.7.</strong> opentofu_validate_test</a></li><li class="chapter-item expanded "><a href="opentofu/extensions.html"><strong aria-hidden="true">3.8.</strong> extensions</a></li></ol></li><li class="chapter-item expanded "><a href="opentofu/settings.html"><strong aria-hidden="true">4.</strong> OpenTofu Settings</a></li></ol>';
        // Set the current, active page, and reveal it if it's hidden
        let current_page = document.location.href.toString().split("#")[0];
        if (current_page.endsWith("/")) {
            current_page += "index.html";
        }
        var links = Array.prototype.slice.call(this.querySelectorAll("a"));
        var l = links.length;
        for (var i = 0; i < l; ++i) {
            var link = links[i];
            var href = link.getAttribute("href");
            if (href && !href.startsWith("#") && !/^(?:[a-z+]+:)?\/\//.test(href)) {
                link.href = path_to_root + href;
            }
            // The "index" page is supposed to alias the first chapter in the book.
            if (link.href === current_page || (i === 0 && path_to_root === "" && current_page.endsWith("/index.html"))) {
                link.classList.add("active");
                var parent = link.parentElement;
                if (parent && parent.classList.contains("chapter-item")) {
                    parent.classList.add("expanded");
                }
                while (parent) {
                    if (parent.tagName === "LI" && parent.previousElementSibling) {
                        if (parent.previousElementSibling.classList.contains("chapter-item")) {
                            parent.previousElementSibling.classList.add("expanded");
                        }
                    }
                    parent = parent.parentElement;
                }
            }
        }
        // Track and set sidebar scroll position
        this.addEventListener('click', function(e) {
            if (e.target.tagName === 'A') {
                sessionStorage.setItem('sidebar-scroll', this.scrollTop);
            }
        }, { passive: true });
        var sidebarScrollTop = sessionStorage.getItem('sidebar-scroll');
        sessionStorage.removeItem('sidebar-scroll');
        if (sidebarScrollTop) {
            // preserve sidebar scroll position when navigating via links within sidebar
            this.scrollTop = sidebarScrollTop;
        } else {
            // scroll sidebar to current active section when navigating via "next/previous chapter" buttons
            var activeSection = document.querySelector('#sidebar .active');
            if (activeSection) {
                activeSection.scrollIntoView({ block: 'center' });
            }
        }
        // Toggle buttons
        var sidebarAnchorToggles = document.querySelectorAll('#sidebar a.toggle');
        function toggleSection(ev) {
            ev.currentTarget.parentElement.classList.toggle('expanded');
        }
        Array.from(sidebarAnchorToggles).forEach(function (el) {
            el.addEventListener('click', toggleSection);
        });
    }
}
window.customElements.define("mdbook-sidebar-scrollbox", MDBookSidebarScrollbox);
