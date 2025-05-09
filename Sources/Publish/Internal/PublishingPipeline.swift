/**
*  Publish
*  Copyright (c) John Sundell 2019
*  MIT license, see LICENSE file for details
*/

import Files

#if canImport(Cocoa)
    import Cocoa
#endif

internal struct PublishingPipeline<Site: Website> {
    let steps: [PublishingStep<Site>]
    let originFilePath: Path
}

extension PublishingPipeline {
    func execute(for site: Site, at path: Path?, output: Path? = nil) async throws
        -> PublishedWebsite<Site>
    {
        let stepKind = resolveStepKind()

        let folders = try setUpFolders(
            withExplicitRootPath: path,
            shouldEmptyOutputFolder: stepKind == .generation,
            output: output
        )

        let steps = self.steps.flatMap { step in
            runnableSteps(ofKind: stepKind, from: step)
        }

        guard let firstStep = steps.first else {
            throw PublishingError(
                infoMessage: """
                    \(site.name) has no \(stepKind.rawValue) steps.
                    """
            )
        }

        var context = PublishingContext(
            site: site,
            folders: folders,
            firstStepName: firstStep.name
        )

        context.generationWillBegin()

        postNotification(named: "WillStart")
        CommandLine.output("Publishing \(site.name) (\(steps.count) steps)", as: .info)

        for (index, step) in steps.enumerated() {
            do {
                let message = "[\(index + 1)/\(steps.count)] \(step.name)"
                CommandLine.output(message, as: .info)
                context.prepareForStep(named: step.name)
                try await step.closure(&context)
            } catch let error as PublishingErrorConvertible {
                throw error.publishingError(forStepNamed: step.name)
            } catch {
                let message = "An unknown error occurred: \(error.localizedDescription)"
                throw PublishingError(infoMessage: message)
            }
        }

        CommandLine.output("Successfully published \(site.name)", as: .success)
        postNotification(named: "DidFinish")

        return PublishedWebsite(
            index: context.index,
            sections: context.sections,
            pages: context.pages
        )
    }
}

extension PublishingPipeline {
    fileprivate typealias Step = PublishingStep<Site>

    fileprivate struct RunnableStep {
        let name: String
        let closure: Step.Closure
    }

    fileprivate func setUpFolders(
        withExplicitRootPath path: Path?,
        shouldEmptyOutputFolder: Bool,
        output: Path? = nil
    ) throws -> Folder.Group {
        do {
            let root = try resolveRootFolder(withExplicitPath: path)

            let outputFolder: Folder
            if let path = output {
                let outputParentFolder = try Folder(path: path.string)
                outputFolder = try outputParentFolder.createSubfolderIfNeeded(withName: "Output")
            } else {
                outputFolder = try root.createSubfolderIfNeeded(withName: "Output")
            }

            if shouldEmptyOutputFolder {
                try? outputFolder.empty(includingHidden: true)
            }

            let internalFolder = try root.createSubfolderIfNeeded(
                withName: ".publish"
            )

            let cacheFolder = try internalFolder.createSubfolderIfNeeded(
                withName: "Caches"
            )

            return Folder.Group(
                root: root,
                output: outputFolder,
                internal: internalFolder,
                caches: cacheFolder
            )
        } catch {
            throw PublishingError(
                path: path,
                infoMessage: "Failed to set up root folder structure"
            )
        }
    }

    fileprivate func resolveRootFolder(withExplicitPath path: Path?) throws -> Folder {
        if let path = path {
            do {
                return try Folder(path: path.string)
            } catch {
                throw PublishingError(
                    path: path,
                    infoMessage: "Could not find the requested root folder"
                )
            }
        }

        let originFile = try File(path: originFilePath.string)
        return try originFile.resolveSwiftPackageFolder()
    }

    fileprivate func resolveStepKind() -> Step.Kind {
        let deploymentFlags: Set<String> = ["--deploy", "-d"]
        let shouldDeploy = CommandLine.arguments.contains(where: deploymentFlags.contains)
        return shouldDeploy ? .deployment : .generation
    }

    fileprivate func runnableSteps(ofKind kind: Step.Kind, from step: Step) -> [RunnableStep] {
        switch step.kind {
        case .system, kind: break
        default: return []
        }

        switch step.body {
        case .empty:
            return []
        case .group(let steps):
            return steps.flatMap { runnableSteps(ofKind: kind, from: $0) }
        case .operation(let name, let closure):
            return [RunnableStep(name: name, closure: closure)]
        }
    }

    fileprivate func postNotification(named name: String) {
        #if canImport(Cocoa)
            let center = DistributedNotificationCenter.default()
            let name = Notification.Name(rawValue: "Publish.\(name)")
            center.post(Notification(name: name))
        #endif
    }
}
