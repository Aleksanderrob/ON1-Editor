import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TripViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.message).lineLimit(1)
                Spacer()
                if !model.photos.isEmpty {
                    Text("\(model.photos.count) photos  ·  \(model.referenceCount) references  ·  \(model.reviewCount) to review")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .alert("ON1 Editor", isPresented: $model.showError) {
            Button("OK") { }
        } message: { Text(model.errorText) }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.filters").font(.title2)
            Text("ON1 Editor").font(.headline)
            if let folder = model.folderURL {
                Text(folder.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Open Trip…", systemImage: "folder") { model.chooseFolder() }
            Button("Export Edited JPEGs…", systemImage: "square.and.arrow.up") { model.exportEdited() }
                .disabled(model.isBusy || model.photos.allSatisfy { $0.plan == nil })
        }
        .padding(14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRIP PHOTOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 14)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.photos) { photo in
                        Button { model.select(photo.id) } label: {
                            HStack(spacing: 10) {
                                PhotoImage(url: photo.previewURL)
                                    .frame(width: 58, height: 45)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(photo.sourceURL.lastPathComponent)
                                        .font(.subheadline).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(photo.scene.rawValue)
                                        if model.preferences.referenceIDs.contains(photo.id) {
                                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                                        }
                                        if photo.result?.status == .outlier {
                                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                        } else if photo.result?.status == .uncertain {
                                            Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
                                        }
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedID == photo.id ? Color.accentColor.opacity(0.20) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let photo = model.selected {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(photo.sourceURL.lastPathComponent).font(.title2.weight(.semibold))
                        Text("\(photo.pixelWidth) × \(photo.pixelHeight)  ·  \(photo.scene.rawValue)")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    if let status = photo.result?.status {
                        Label(status.rawValue, systemImage: status == .pass ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(status == .pass ? .green : .orange)
                    }
                    Button(model.preferences.referenceIDs.contains(photo.id) ? "Remove Reference" : "Use as Reference",
                           systemImage: model.preferences.referenceIDs.contains(photo.id) ? "star.fill" : "star") {
                        model.toggleReference(photo.id)
                    }
                    .disabled(model.isBusy)
                }
                HStack(spacing: 12) {
                    preview(photo.previewURL, title: "Original")
                    preview(photo.editedPreviewURL ?? photo.previewURL,
                            title: photo.editedPreviewURL == nil ? "Choose a reference to preview edits" : "Edited preview")
                }
                .frame(maxHeight: .infinity)
                if let plan = photo.plan {
                    planPanel(plan, photo: photo)
                } else {
                    Text("Choose one or more reference photos. ON1 Editor will compare every image with that look and create individual edits.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        } else {
            ContentUnavailableView("Open a trip folder", systemImage: "photo.on.rectangle.angled",
                description: Text("Choose a folder of travel photos to start building a consistent look."))
        }
    }

    private func preview(_ url: URL, title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            PhotoImage(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func planPanel(_ plan: EditPlan, photo: PhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Individual edit plan").font(.headline)
                Spacer()
                Text("Confidence \(Int(plan.confidence * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(plan.rationale.isEmpty ? "No correction needed" : plan.rationale.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                metric("Exposure", String(format: "%+.2f EV", plan.exposureEV))
                metric("Contrast", String(format: "%.2f×", plan.contrast))
                metric("Saturation", String(format: "%.2f×", plan.saturation))
                metric("Warmth", String(format: "%+.2f", plan.warmth))
            }
            if !model.preferences.referenceIDs.contains(photo.id) {
                Divider()
                Text("Your correction").font(.subheadline.weight(.medium))
                HStack(spacing: 16) {
                    correctionSlider("Exposure", value: $model.draftCorrection.exposureEV, range: -1...1)
                    correctionSlider("Contrast", value: $model.draftCorrection.contrast, range: -0.2...0.2)
                    correctionSlider("Saturation", value: $model.draftCorrection.saturation, range: -0.3...0.3)
                    correctionSlider("Warmth", value: $model.draftCorrection.warmth, range: -0.3...0.3)
                }
                HStack {
                    Text("Applied corrections inform future plans for similar lighting.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { model.resetCorrection() }
                    Button("Apply Correction") { model.applyCorrection() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .disabled(model.isBusy)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit())
        }
    }

    private func correctionSlider(_ label: String, value: Binding<Double>,
                                  range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: "%+.2f", value.wrappedValue))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PhotoImage: View {
    let url: URL
    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").resizable().scaledToFit().padding()
            }
        }
    }
}
