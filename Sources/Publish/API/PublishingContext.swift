/**
*  Publish
*  Copyright (c) John Sundell 2019
*  MIT license, see LICENSE file for details
*/

import Codextended
import Files
import Foundation
import Ink
import Plot

/// Type that represents the context in which a website is being published.
/// It can be used to manipulate the state of the website in various ways,
/// including mutating and adding new content, creating new files and folders,
/// and so on. Each `PublishingStep` gets access to the current context.
public struct PublishingContext<Site: Website> {
    /// The website that this context is for.
    public let site: Site
    /// The Markdown parser that this publishing session is using. You can
    /// add modifiers to it to customize how each Markdown string is rendered.
    public var markdownParser = MarkdownParser()
    /// The date formatter that this publishing session is using when parsing
    /// dates from Markdown files.
    public var dateFormatter: DateFormatter
    /// A representation of the website's main index page.
    public var index = Index()
    /// The sections that the website contains.
    public var sections = SectionMap<Site>() { didSet { tagCache.tags = nil } }
    /// The free-form pages that the website contains.
    public private(set) var pages = [Path: Page]()
    /// A set containing all tags that are currently being used website-wide.
    public var allTags: Set<Tag> { tagCache.tags ?? gatherAllTags() }
    /// Any date when the website was last generated.
    public private(set) var lastGenerationDate: Date?

    private let folders: Folder.Group
    private var tagCache = TagCache()
    private var stepName: String

    internal init(
        site: Site,
        folders: Folder.Group,
        firstStepName: String
    ) {
        self.site = site
        self.folders = folders
        self.stepName = firstStepName

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = .current
        self.dateFormatter = dateFormatter
    }
}

extension PublishingContext {
    /// Retrieve a folder at a given path, starting from the website's root folder.
    /// - parameter path: The path to retrieve a folder for.
    /// - throws: An error in case the folder couldn't be found.
    public func folder(at path: Path) throws -> Folder {
        do { return try folders.root.subfolder(at: path.string) } catch {
            throw FileIOError(path: path, reason: .folderNotFound)
        }
    }

    /// Retrieve a file at a given path, starting from the website's root folder.
    /// - parameter path: The path to retrieve a file for.
    /// - throws: An error in case the file couldn't be found.
    public func file(at path: Path) throws -> File {
        do { return try folders.root.file(at: path.string) } catch {
            throw FileIOError(path: path, reason: .fileNotFound)
        }
    }

    /// Retrieve a folder within the website's output folder.
    /// - parameter path: The path to retrieve a folder for.
    /// - throws: An error in case the folder couldn't be found.
    public func outputFolder(at path: Path) throws -> Folder {
        do { return try folders.output.subfolder(at: path.string) } catch {
            throw FileIOError(path: path, reason: .folderNotFound)
        }
    }

    /// Retrieve a file within the website's output folder.
    /// - parameter path: The path to retrieve a file for.
    /// - throws: An error in case the file couldn't be found.
    public func outputFile(at path: Path) throws -> File {
        do { return try folders.output.file(at: path.string) } catch {
            throw FileIOError(path: path, reason: .fileNotFound)
        }
    }

    /// Create a folder at a given path, starting from the website's root folder.
    /// - parameter path: The path to create a folder at.
    /// - throws: An error in case the folder couldn't be created.
    public func createFolder(at path: Path) throws -> Folder {
        try createFolder(at: path, in: folders.root)
    }

    /// Create a file at a given path, starting from the website's root folder.
    /// - parameter path: The path to create a file at.
    /// - throws: An error in case the file couldn't be created.
    public func createFile(at path: Path) throws -> File {
        try createFile(at: path, in: folders.root)
    }

    /// Create a folder at a given path within the website's output folder.
    /// - parameter path: The path to create a folder at.
    /// - throws: An error in case the folder couldn't be created.
    public func createOutputFolder(at path: Path) throws -> Folder {
        try createFolder(at: path, in: folders.output)
    }

    /// Create a file at a given path within the website's output folder.
    /// - parameter path: The path to create a file at.
    /// - throws: An error in case the file couldn't be created.
    public func createOutputFile(at path: Path) throws -> File {
        try createFile(at: path, in: folders.output)
    }

    /// Copy a folder at a given path into the website's output folder.
    /// - parameter originPath: The path of the folder to copy.
    /// - parameter targetFolderPath: Any specific path to copy the folder to.
    ///   If `nil`, then the folder will be copied to the output folder itself.
    public func copyFolderToOutput(
        from originPath: Path,
        to targetFolderPath: Path? = nil
    ) throws {
        let folder = try self.folder(at: originPath)
        try copyFolderToOutput(folder, targetFolderPath: targetFolderPath)
    }

    /// Copy a file at a given path into the website's output folder.
    /// - parameter originPath: The path of the file to copy.
    /// - parameter targetFolderPath: Any specific folder path to copy the file to.
    ///   If `nil`, then the file will be copied to the output folder itself.
    public func copyFileToOutput(
        from originPath: Path,
        to targetFolderPath: Path? = nil
    ) throws {
        let file = try self.file(at: originPath)
        try copyFileToOutput(file, targetFolderPath: targetFolderPath)
    }

    /// Create a folder suitable for deployment. Any existing folder will be emptied
    /// (apart from hidden files) before being passed to the given configure closure.
    /// After that, all output files and folders will be copied into the new folder.
    /// - Parameter prefix: What prefix to apply to the folder, typically
    ///   the name of the current deployment method.
    /// - parameter outputFolderPath: Any specific subfolder path to copy the output to.
    ///   If `nil`, then the output will be copied to the deployment folder itself.
    /// - Parameter configure: A closure used to configure the folder.
    public func createDeploymentFolder(
        withPrefix prefix: String,
        outputFolderPath: Path? = nil,
        configure: (Folder) throws -> Void
    ) throws -> Folder {
        let path = Path(prefix + "Deploy")

        let folder = try createFolder(at: path, in: folders.internal)
        try folder.empty()

        do {
            try configure(folder)
        } catch {
            throw FileIOError(
                path: path,
                reason: .deploymentFolderSetupFailed(error)
            )
        }

        var outputFolder = folder

        if let outputFolderPath = outputFolderPath {
            outputFolder = try folder.createSubfolder(at: outputFolderPath.string)
        }

        do {
            try folders.output.subfolders.forEach { try $0.copy(to: outputFolder) }
            try folders.output.files.includingHidden.forEach { try $0.copy(to: outputFolder) }
            return folder
        } catch {
            throw FileIOError(path: path, reason: .folderCreationFailed)
        }
    }

    /// Return either an existing or newly created cache file for the
    /// current publishing step. Cache files are scoped to the step
    /// that they're created within, and can't be shared among steps.
    /// Cache files aren't deleted in between publishing processes.
    /// - parameter name: The name of the cache file to return.
    /// - throws: An error in case a new file couldn't be created.
    public func cacheFile(named name: String) throws -> File {
        let folderName = stepName.normalized()
        let folder = try folders.caches.createSubfolderIfNeeded(withName: folderName)
        return try folder.createFileIfNeeded(withName: name.normalized())
    }

    /// Return all items within this website, sorted by a given key path.
    /// - parameter sortingKeyPath: The key path to sort the items by.
    /// - parameter order: The order to use when sorting the items.
    public func allItems<T: Comparable>(
        sortedBy sortingKeyPath: KeyPath<Item<Site>, T>,
        order: SortOrder = .ascending
    ) -> [Item<Site>] {
        let items = sections.flatMap { $0.items }

        return items.sorted(
            by: order.makeSorter(forKeyPath: sortingKeyPath)
        )
    }

    /// Return all items that were tagged with a given tag.
    /// - parameter tag: The tag to return all items for.
    public func items(taggedWith tag: Tag) -> [Item<Site>] {
        sections.flatMap { $0.items(taggedWith: tag) }
    }

    /// Return all items that were tagged with a given tag, sorted by
    /// a given key path.
    /// - parameter tag: The tag to return all items for.
    /// - parameter sortingKeyPath: The key path to sort the items by.
    /// - parameter order: The order to use when sorting the items.
    public func items<T: Comparable>(
        taggedWith tag: Tag,
        sortedBy sortingKeyPath: KeyPath<Item<Site>, T>,
        order: SortOrder = .ascending
    ) -> [Item<Site>] {
        items(taggedWith: tag).sorted(
            by: order.makeSorter(forKeyPath: sortingKeyPath)
        )
    }

    /// Add an item to the website programmatically.
    /// - parameter item: The item to add.
    public mutating func addItem(_ item: Item<Site>) {
        sections[item.sectionID].addItem(item)
    }

    /// Add a page to the website programmatically.
    /// - parameter page: The page to add.
    public mutating func addPage(_ page: Page) {
        pages[page.path] = page
    }

    /// Mutate all of the website's sections using a closure.
    /// - parameter mutations: The mutations to apply to each section.
    public mutating func mutateAllSections(using mutations: Mutations<Section<Site>>) rethrows {
        for id in sections.ids {
            try mutations(&sections[id])
        }
    }

    /// Mutate one of the website's existing pages.
    /// - parameter path: The path of the page to mutate.
    /// - parameter predicate: Any predicate to match against before mutating the page.
    /// - parameter mutations: The mutations to apply to the page.
    /// - throws: An error in case the page couldn't be found, or
    ///   if the mutation close itself threw an error.
    public mutating func mutatePage(
        at path: Path,
        matching predicate: Predicate<Page> = .any,
        using mutations: Mutations<Page>
    ) throws {
        guard var page = pages[path] else {
            throw ContentError(path: path, reason: .pageNotFound)
        }

        guard predicate.matches(page) else {
            return
        }

        do {
            try mutations(&page)
            pages[page.path] = page

            if page.path != path {
                pages[path] = nil
            }
        } catch {
            throw ContentError(
                path: page.path,
                reason: .pageMutationFailed(error)
            )
        }
    }
}

extension PublishingContext {
    mutating func generationWillBegin() {
        try? updateLastGenerationDate()
    }

    mutating func prepareForStep(named name: String) {
        stepName = name
    }

    func makeMarkdownContentFactory() -> MarkdownContentFactory<Site> {
        MarkdownContentFactory(
            parser: markdownParser,
            dateFormatter: dateFormatter
        )
    }

    func copyFileToOutput(
        _ file: File,
        targetFolderPath: Path?
    ) throws {
        try copyLocationToOutput(
            file,
            targetFolderPath: targetFolderPath,
            errorReason: .fileCopyingFailed
        )
    }

    func copyFolderToOutput(
        _ folder: Folder,
        targetFolderPath: Path?
    ) throws {
        try copyLocationToOutput(
            folder,
            targetFolderPath: targetFolderPath,
            errorReason: .folderCopyingFailed
        )
    }
}

extension PublishingContext {
    fileprivate final class TagCache {
        var tags: Set<Tag>?
    }

    fileprivate mutating func updateLastGenerationDate() throws {
        let fileName = "lastGenerationDate"
        let newString = String(Date().timeIntervalSince1970)

        if let file = try? folders.internal.file(named: fileName) {
            let oldInterval = try TimeInterval(file.readAsString())

            lastGenerationDate = oldInterval.map {
                Date(timeIntervalSince1970: $0)
            }

            try file.write(newString)
        } else {
            let file = try folders.internal.createFile(named: fileName)
            try file.write(newString)
        }
    }

    fileprivate func gatherAllTags() -> Set<Tag> {
        var tags = Set<Tag>()

        for section in sections {
            tags.formUnion(section.allTags)
        }

        tagCache.tags = tags
        return tags
    }

    fileprivate func copyLocationToOutput<T: Files.Location>(
        _ location: T,
        targetFolderPath: Path?,
        errorReason: FileIOError.Reason
    ) throws {
        let targetFolder = try targetFolderPath.map {
            try createOutputFolder(at: $0)
        }

        do {
            let folder = targetFolder ?? folders.output
            let adjustedFolder = try Folder(path: folder.path + "/")
            try location.copy(to: adjustedFolder)
        } catch {
            let path = Path(location.path(relativeTo: folders.root))
            throw FileIOError(path: path, reason: errorReason)
        }
    }

    fileprivate func createFolder(at path: Path, in folder: Folder) throws -> Folder {
        do {
            return try folder.createSubfolderIfNeeded(at: path.string)
        } catch {
            let path = Path(folder.path + path.string)
            throw FileIOError(path: path, reason: .folderCreationFailed)
        }
    }

    fileprivate func createFile(at path: Path, in folder: Folder) throws -> File {
        do {
            return try folder.createFileIfNeeded(at: path.string)
        } catch {
            let path = Path(folder.path + path.string)
            throw FileIOError(path: path, reason: .fileCreationFailed)
        }
    }
}
