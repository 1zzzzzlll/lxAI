# Office 使用说明

Office Worker 内置 python-docx、openpyxl、xlsxwriter、pandas、python-pptx、pptxgenjs、PyMuPDF、pypdf、LibreOffice、Pandoc、Poppler 以及 Noto/DejaVu 字体。

DOCX、XLSX 和 PPTX 在生成或修改后会先用对应 Python 库重新打开，再用 LibreOffice Headless 转 PDF，最后由 PyMuPDF 打开 PDF 并读取页数。任一阶段失败均返回错误，不会把未验证文件标成成功。

主要接口包括 `create/edit/read_docx`、`create/edit/merge/analyze/read_xlsx`、`create/edit/read_pptx`、`office_to_pdf`、`read_pdf`、`pdf_to_images`、`merge_pdf` 和 `split_pdf`。PPT 页面可用 `table`、`chart`（bar/line/pie）和通用 `boxes` 生成表格、图表、流程/架构/时间线元素。

模板目录：`/TRS/lxAI/templates/word`、`excel`、`ppt`。模板属于用户资产，离线包只创建目录和示例说明，不分发 Microsoft 字体或受限商业模板。
