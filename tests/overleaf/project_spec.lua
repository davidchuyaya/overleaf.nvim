local project = require('overleaf.project')

describe('project tree mutations', function()
  local original_tree

  before_each(function()
    original_tree = project._project_tree
    project._project_tree = {
      { id = 'folder', name = 'old', path = 'old/', type = 'folder' },
      { id = 'child', name = 'main.tex', path = 'old/main.tex', type = 'doc' },
      { id = 'other', name = 'other.tex', path = 'other.tex', type = 'doc' },
    }
  end)

  after_each(function() project._project_tree = original_tree end)

  it('removes a folder and all of its children', function()
    assert.is_true(project.remove_entry('folder'))
    assert.is_nil(project.get_doc_by_id('folder'))
    assert.is_nil(project.get_doc_by_id('child'))
    assert.is_not_nil(project.get_doc_by_id('other'))
  end)
end)
